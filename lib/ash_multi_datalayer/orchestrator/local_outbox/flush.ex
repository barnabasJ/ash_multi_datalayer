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
       (post-commit); a semantic **rejection**/**conflict** parks in-action, an
       **auth** failure (`Forbidden`) parks in-action too — immediately, no
       retries burned, since a token doesn't un-expire by retrying — and
       everything else raises as transient (Oban retries → `on_error` parks
       as `:transient_exhausted`).

  Deliberately **no** offline/transport error class: a target may be ETS/Mnesia
  with no network at all. A failed push retries then parks; the application pauses
  the queue (`pause_sync/1`) when it detects it cannot sync.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias AshMultiDatalayer.Orchestrator.LocalOutbox
  alias AshMultiDatalayer.Orchestrator.LocalOutbox.{HostResolver, Snapshot, Target}
  alias AshMultiDatalayer.Sync.Enqueue

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &flush/1)
  end

  defp flush(changeset) do
    outbox = changeset.resource
    domain = Ash.Resource.Info.domain(outbox)
    entry = changeset.data

    case HostResolver.resolve(outbox, entry.resource) do
      {:ok, host} ->
        case chain_position(outbox, domain, entry) do
          :head ->
            # H4/#14: `entry` is however-stale ash_oban's initial
            # `worker_read_action :pending` read left it — an in-flight
            # `write_through`'s inline drain (`Write.drain_chain_inline/3`,
            # same PK) can push and discard this exact entry in the window
            # between that read and this push. Re-fetch immediately before
            # pushing (the smallest achievable window — a push to a target
            # is inherently non-transactional with the local outbox state,
            # so this narrows the race rather than eliminating it
            # mathematically): if the entry is gone, someone already
            # resolved it — a clean no-op, not a stale re-push.
            case refetch(outbox, domain, entry) do
              nil ->
                changeset

              entry ->
                apply_result(changeset, outbox, domain, host, entry, push(host, entry))
            end

          :racing ->
            # A pending ancestor is still ahead; try again shortly (zero budget burn).
            raise AshOban.Errors.SnoozeJob, snooze_for: reorder_snooze()

          :blocked ->
            # A parked ancestor blocks the chain; hold without change. Resolving that
            # head re-kicks this chain.
            changeset
        end

      :error ->
        # A stale outbox row naming a resource this app no longer defines (a
        # deploy/boot-ordering artifact, M-11) — park immediately rather than
        # burn retries chasing a resource that can never resolve.
        park(
          changeset,
          :rejected,
          %{"reason" => "unresolvable LocalOutbox host resource: #{entry.resource}"},
          nil
        )
    end
  end

  # A single fresh read of this exact row by its real PK (`seq`) — `nil` if
  # it no longer exists (already discarded).
  defp refetch(outbox, domain, entry) do
    outbox
    |> Ash.Query.for_read(
      :for_record,
      %{resource: entry.resource, record_pk: entry.record_pk, target: entry.target},
      domain: domain,
      authorize?: false
    )
    |> Ash.Query.filter(seq == ^entry.seq)
    |> Ash.read_one!(authorize?: false)
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
      |> tenant_filter(entry.tenant)
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

      :auth ->
        # A token/credential problem never un-expires by retrying — park
        # immediately, no retry-budget burn (M-6). `retry/1` re-flushes once
        # the operator fixes the underlying credentials.
        park(changeset, :auth, error_map(error), nil)

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
    |> tenant_filter(entry.tenant)
    |> Ash.Query.sort(seq: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [next | _] -> Enqueue.flush_and_log(outbox, next)
      [] -> :ok
    end
  end

  defp tenant_filter(query, nil), do: Ash.Query.filter(query, is_nil(tenant))
  defp tenant_filter(query, tenant), do: Ash.Query.filter(query, tenant == ^to_string(tenant))

  # --- push to the target -----------------------------------------------

  @doc false
  def push(host, %{op: :destroy} = entry) do
    with :ok <- check_stale(host, entry) do
      normalize(
        Target.destroy(host, entry.target, Target.record_from_entry(host, entry),
          tenant: entry.tenant
        )
      )
    end
  end

  def push(host, entry) do
    with :ok <- check_stale(host, entry) do
      normalize(
        Target.upsert(host, entry.target, Target.record_from_entry(host, entry),
          tenant: entry.tenant
        )
      )
    end
  end

  # L12 item 6, explicit decision recorded (spec review required a real
  # call here, not just a doc note): `:upsert` intentionally bypasses
  # stale-check even when `conflict_detection` is `{:stale_check, _}`.
  #
  # Stale-check works by comparing a remembered BEFORE-image to the
  # target's current value — but an upsert's local write never read a
  # prior value in the first place (that is what distinguishes "upsert"
  # from "update": the caller does not know, and does not need to know,
  # whether a row already exists). There is no before-image to compare
  # against, and `write.ex`'s `base_image/3` correctly returns `nil` for
  # `:upsert` for exactly this reason.
  #
  # A guard that instead treats "the target already has a row" as a
  # conflict would be actively wrong: that is upsert's ordinary,
  # expected case (create-if-absent, else-update) — not a divergence.
  # It would park every upsert-onto-an-existing-row, which is most of
  # them.
  #
  # This means an upsert's local value always wins over a target's
  # already-diverged row (LWW), even with stale-check enabled elsewhere
  # for the same host. This is judged acceptable because `:upsert`'s own
  # contract is inherently "this identity's value should be exactly what
  # I say" — the same semantic Ash's own `upsert_condition`/identity-based
  # upsert already expresses at the application level, independent of
  # replication. A caller that needs conflict-safe semantics for a
  # specific write should use `:update` (which DOES get stale-check
  # protection) instead of `:upsert`.
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
    case Target.read_pk(host, entry.target, entry.record_pk, tenant: entry.tenant) do
      {:ok, nil} ->
        if entry.op == :update and not is_nil(entry.base_image) do
          {:conflict, nil}
        else
          :ok
        end

      {:ok, remote} ->
        if remote_matches_payload?(host, entry, remote) do
          :ok
        else
          # `base_image` was stored in the outbox's `:map` attribute and read back
          # through a JSON round-trip, so its values are JSON scalars (a
          # `DateTime` became an ISO string). Normalise the freshly-dumped remote
          # value the same way before comparing — otherwise a stale-check on a
          # `:utc_datetime_usec`/`:decimal` field would compare a string to a
          # struct and park EVERY flush as a false conflict.
          expected = json_scalar(entry.base_image && entry.base_image[to_string(field)])
          actual = json_scalar(dump_field(host, field, Map.get(remote, field)))
          if expected == actual, do: :ok, else: {:conflict, Snapshot.dump(host, remote)}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp dump_field(host, field, value) do
    attribute = Ash.Resource.Info.attribute(host, field)
    {:ok, dumped} = Ash.Type.dump_to_embedded(attribute.type, value, attribute.constraints)
    dumped
  end

  defp remote_matches_payload?(_host, %{payload: nil}, _remote), do: false

  # `entry.payload` was stored in the outbox's `:map` attribute and read back
  # through a JSON round-trip (JSON scalars — a `DateTime` became an ISO
  # string); `Snapshot.dump/2` yields embedded values (structs). Normalise
  # both sides the same way the field-level compare below already does —
  # otherwise this fast path never matches for a `:utc_datetime_usec`/
  # `:decimal` field, and an already-applied retry falsely parks as a
  # conflict (B6/#5). Covers `drain_chain_inline` too — it calls this same
  # `push/2`.
  defp remote_matches_payload?(host, entry, remote) do
    json_scalar(Snapshot.dump(host, remote)) == json_scalar(entry.payload)
  end

  # Reduce a value to the JSON scalar the outbox `:map` round-trip would yield,
  # so a base-image string compares equal to a freshly-dumped struct/number.
  defp json_scalar(nil), do: nil
  defp json_scalar(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp normalize(:ok), do: :ok
  defp normalize({:ok, _record}), do: :ok
  defp normalize({:error, error}), do: {:error, error}

  # --- error classification (semantic rejection vs auth vs transient) ---

  @doc false
  # No offline class (targets can be networkless). Three classes: a semantic
  # rejection the replica will never accept (park now), an auth/credential
  # failure that will never fix itself by retrying (park now, `:auth` — M-6:
  # a token does not un-expire by retrying, and burning the retry budget
  # before parking masks the likely-production failure as flakiness), and
  # everything else (transient — retry, then park on exhaustion).
  def classify({:rejected, _}), do: :rejected
  def classify({:transient, _}), do: :transient
  def classify(%Ash.Error.Invalid{}), do: :rejected
  def classify(%{class: :invalid}), do: :rejected
  def classify(%Ash.Error.Forbidden{}), do: :auth
  def classify(%{class: :forbidden}), do: :auth
  def classify({:http_error, status, _}) when status in [401, 403], do: :auth
  def classify(%{status: status}) when status in [401, 403], do: :auth
  def classify(_error), do: :transient

  defp error_map({_tag, reason}), do: %{"reason" => inspect(reason)}
  defp error_map(error), do: %{"reason" => inspect(error)}

  defp reorder_snooze do
    Application.get_env(:ash_multi_datalayer, :outbox_reorder_snooze_seconds, 1)
  end
end
