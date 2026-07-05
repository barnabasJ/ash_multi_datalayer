defmodule AshMultiDatalayer.Orchestrator.LocalOutbox.Flush do
  @moduledoc """
  The body of the outbox `:flush` **update** action (library code, so fixes ship
  in the library, not in generated user files). ash_oban's update-trigger machinery
  owns the framing — `worker_read_action :pending` re-checks relevance, retries are
  Oban's, `on_error :park` parks on transient exhaustion. This change is only the
  irreducible per-flush logic:

    1. **Chain position** on `seq` — per-PK FIFO enforced in data (Oban gives no
       execution order). Behind a pending ancestor → snooze (racing); behind a
       parked ancestor → hold (the chain is blocked until that head is resolved).
    2. **Push** the entry to `target` via `Backfill`, honouring `conflict_detection`.
    3. **Mark** the entry `:synced` and kick the next pending chain entry
       (post-commit); a semantic **rejection**/**conflict** parks in-action, a
       transient error raises (Oban retries → `on_error` parks).

  Deliberately **no** offline/transport error class: a target may be ETS/Mnesia
  with no network at all. A failed push retries then parks; the application pauses
  the queue (`pause_sync/1`) when it detects it cannot sync.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias AshMultiDatalayer.Orchestrator.LocalOutbox
  alias AshMultiDatalayer.Orchestrator.LocalOutbox.{Snapshot, Target}
  alias AshMultiDatalayer.Sync.Enqueue

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &flush/1)
  end

  defp flush(changeset) do
    outbox = changeset.resource
    domain = Ash.Resource.Info.domain(outbox)
    entry = changeset.data
    host = String.to_existing_atom(entry.resource)

    case chain_position(outbox, domain, entry) do
      :head ->
        apply_result(changeset, outbox, domain, host, entry, push(host, entry))

      :racing ->
        # A pending ancestor is still ahead; try again shortly (zero budget burn).
        raise AshOban.Errors.SnoozeJob, snooze_for: reorder_snooze()

      :blocked ->
        # A parked ancestor blocks the chain; hold without change. Resolving that
        # head re-kicks this chain.
        changeset
    end
  end

  # --- chain position ----------------------------------------------------

  @doc "`:head` | `:racing` (pending ancestor) | `:blocked` (parked ancestor)."
  def chain_position(outbox, domain, entry) do
    ahead =
      outbox
      |> Ash.Query.for_read(
        :for_record,
        %{resource: entry.resource, record_pk: entry.record_pk, target: entry.target},
        domain: domain,
        authorize?: false
      )
      |> Ash.Query.filter(seq < ^entry.seq and state != :synced)
      |> Ash.read!(authorize?: false)

    cond do
      Enum.any?(ahead, &(&1.state == :parked)) -> :blocked
      ahead != [] -> :racing
      true -> :head
    end
  end

  @doc false
  def chain_head?(outbox, domain, entry), do: chain_position(outbox, domain, entry) == :head

  # --- apply the flush result to the changeset --------------------------

  defp apply_result(changeset, outbox, domain, host, _entry, :ok) do
    changeset
    |> Ash.Changeset.force_change_attribute(:state, :synced)
    |> Ash.Changeset.after_action(fn _cs, synced ->
      kick_next(outbox, domain, host, synced)
      {:ok, synced}
    end)
  end

  defp apply_result(changeset, _outbox, _domain, _host, _entry, {:conflict, remote}) do
    park(changeset, :conflict, %{}, remote)
  end

  defp apply_result(changeset, _outbox, _domain, _host, entry, {:error, error}) do
    case classify(error) do
      :rejected ->
        park(changeset, :rejected, error_map(error), nil)

      :transient ->
        # Retry via Oban backoff; `on_error :park` fires on exhaustion.
        raise "LocalOutbox flush transient failure for #{entry.resource}: #{inspect(error)}"
    end
  end

  defp park(changeset, error_class, last_error, remote_snapshot) do
    changeset
    |> Ash.Changeset.force_change_attribute(:state, :parked)
    |> Ash.Changeset.force_change_attribute(:error_class, error_class)
    |> Ash.Changeset.force_change_attribute(:last_error, last_error)
    |> Ash.Changeset.force_change_attribute(:remote_snapshot, remote_snapshot)
    |> Ash.Changeset.force_change_attribute(:parked_at, DateTime.utc_now())
  end

  defp kick_next(outbox, domain, _host, entry) do
    outbox
    |> Ash.Query.for_read(
      :for_record,
      %{resource: entry.resource, record_pk: entry.record_pk, target: entry.target},
      domain: domain,
      authorize?: false
    )
    |> Ash.Query.filter(state == :pending)
    |> Ash.Query.sort(seq: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [next | _] -> Enqueue.flush(outbox, next)
      [] -> :ok
    end
  end

  # --- push to the target -----------------------------------------------

  @doc false
  def push(host, %{op: :destroy} = entry) do
    with :ok <- check_stale(host, entry) do
      normalize(Target.destroy(host, entry.target, Target.record_from_entry(host, entry)))
    end
  end

  def push(host, entry) do
    with :ok <- check_stale(host, entry) do
      normalize(Target.upsert(host, entry.target, Target.record_from_entry(host, entry)))
    end
  end

  defp check_stale(host, entry) do
    case LocalOutbox.conflict_detection(host) do
      :off ->
        :ok

      {:stale_check, field} when entry.op in [:update, :destroy] ->
        stale_check(host, entry, field)

      {:stale_check, _field} ->
        :ok
    end
  end

  defp stale_check(host, entry, field) do
    case Target.read_pk(host, entry.target, entry.record_pk) do
      {:ok, nil} ->
        :ok

      {:ok, remote} ->
        # `base_image` was stored in the outbox's `:map` attribute and read back
        # through a JSON round-trip, so its values are JSON scalars (a
        # `DateTime` became an ISO string). Normalise the freshly-dumped remote
        # value the same way before comparing — otherwise a stale-check on a
        # `:utc_datetime_usec`/`:decimal` field would compare a string to a
        # struct and park EVERY flush as a false conflict.
        expected = json_scalar(entry.base_image && entry.base_image[to_string(field)])
        actual = json_scalar(dump_field(host, field, Map.get(remote, field)))
        if expected == actual, do: :ok, else: {:conflict, Snapshot.dump(host, remote)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp dump_field(host, field, value) do
    attribute = Ash.Resource.Info.attribute(host, field)
    {:ok, dumped} = Ash.Type.dump_to_embedded(attribute.type, value, attribute.constraints)
    dumped
  end

  # Reduce a value to the JSON scalar the outbox `:map` round-trip would yield,
  # so a base-image string compares equal to a freshly-dumped struct/number.
  defp json_scalar(nil), do: nil
  defp json_scalar(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp normalize(:ok), do: :ok
  defp normalize({:ok, _record}), do: :ok
  defp normalize({:error, error}), do: {:error, error}

  # --- error classification (semantic rejection vs transient) -----------

  @doc false
  # No offline class (targets can be networkless). Only two classes: a semantic
  # rejection the replica will never accept (park now), and everything else
  # (transient — retry, then park on exhaustion).
  def classify({:rejected, _}), do: :rejected
  def classify({:transient, _}), do: :transient
  def classify(%Ash.Error.Invalid{}), do: :rejected
  def classify(%{class: :invalid}), do: :rejected
  def classify(_error), do: :transient

  defp error_map({_tag, reason}), do: %{"reason" => inspect(reason)}
  defp error_map(error), do: %{"reason" => inspect(error)}

  defp reorder_snooze do
    Application.get_env(:ash_multi_datalayer, :outbox_reorder_snooze_seconds, 1)
  end
end
