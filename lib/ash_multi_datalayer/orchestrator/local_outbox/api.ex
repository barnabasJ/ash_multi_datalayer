defmodule AshMultiDatalayer.Orchestrator.LocalOutbox.Api do
  @moduledoc """
  The LocalOutbox public surface: awaitable handles, queryable outbox state,
  resolution verbs, sync pause/resume, inbound `refresh/3` + hydration, and the
  notification-bridge callbacks. Re-exported from
  `AshMultiDatalayer.Orchestrator.LocalOutbox`.
  """
  require Ash.Query
  require Logger

  alias AshMultiDatalayer.Backfill
  alias AshMultiDatalayer.Orchestrator.LocalOutbox
  alias AshMultiDatalayer.Orchestrator.LocalOutbox.{Snapshot, Target}
  alias AshMultiDatalayer.Sync.Enqueue
  alias AshMultiDatalayer.Sync.Info, as: SyncInfo

  # --- queryable state ---------------------------------------------------

  @doc "Pending entries for a host resource (optionally scoped to a tenant)."
  @spec pending(Ash.Resource.t(), term()) :: [Ash.Resource.record()]
  def pending(host_resource, tenant \\ nil) do
    host_resource
    |> outbox()
    |> base_query(host_resource, tenant)
    |> Ash.Query.filter(state == :pending)
    |> Ash.Query.sort(seq: :asc)
    |> read()
  end

  @doc "Parked entries for a host resource (optionally scoped to a tenant)."
  @spec parked(Ash.Resource.t(), term()) :: [Ash.Resource.record()]
  def parked(host_resource, tenant \\ nil) do
    host_resource
    |> outbox()
    |> base_query(host_resource, tenant)
    |> Ash.Query.filter(state == :parked)
    |> Ash.Query.sort(seq: :asc)
    |> read()
  end

  @doc """
  Per-record sync status: `:synced` | `:pending` | `{:parked, entries}`. Accepts
  any host record (read from the local layer or freshly returned by a write) — it
  looks up the record's outbox chain by primary key, so a local-first UI can poll
  `status/1` for a "saving… / saved / sync failed" badge on every row.
  """
  @spec status(Ash.Resource.record()) :: :synced | :pending | {:parked, [Ash.Resource.record()]}
  def status(%_{} = record) do
    host = record.__struct__
    pk = Snapshot.record_pk(host, record)

    entries =
      host
      |> outbox()
      |> base_query(host, tenant_of(record))
      |> Ash.Query.filter(record_pk == ^pk)
      |> Ash.Query.sort(seq: :asc)
      |> read()

    cond do
      # Flush marks entries :synced (idiomatic update trigger) — a record is synced
      # once none of its entries are still pending or parked.
      entries == [] or Enum.all?(entries, &(&1.state == :synced)) ->
        :synced

      Enum.any?(entries, &(&1.state == :parked)) ->
        {:parked, Enum.filter(entries, &(&1.state == :parked))}

      true ->
        :pending
    end
  end

  @doc """
  Block until every entry of a write is flushed (`:synced`), any parks
  (`{:parked, entries}`), or the timeout elapses (`:timeout`). Polls the outbox —
  the initial read means no transition is missable (the await/2 race).
  """
  @spec await(Ash.Resource.record(), keyword()) ::
          :synced | {:parked, [Ash.Resource.record()]} | :timeout
  def await(record_or_ref, opts \\ []) do
    deadline = now_ms() + Keyword.get(opts, :timeout, 5_000)
    interval = Keyword.get(opts, :interval, 25)
    do_await(record_or_ref, deadline, interval)
  end

  defp do_await(record_or_ref, deadline, interval) do
    case status(record_or_ref) do
      :synced ->
        :synced

      {:parked, entries} ->
        {:parked, entries}

      :pending ->
        if now_ms() >= deadline do
          :timeout
        else
          Process.sleep(interval)
          do_await(record_or_ref, deadline, interval)
        end
    end
  end

  # --- resolution verbs (operate on an outbox entry record) --------------

  @doc "parked → pending, re-trigger the chain head (after the operator fixed the cause)."
  @spec retry(Ash.Resource.record()) :: :ok
  def retry(entry) do
    outbox = entry.__struct__

    updated =
      entry
      |> Ash.Changeset.for_update(:retry, %{}, domain: domain(outbox))
      |> Ash.update!(authorize?: false)

    Enqueue.flush(outbox, updated)
    :ok
  end

  @doc """
  Drop an entry. Discarding a `:create` drops its whole PK chain (loudly, in the
  return); otherwise drops just this entry.
  """
  @spec discard(Ash.Resource.record()) ::
          {:ok, %{discarded: pos_integer(), dropped_chain: boolean()}}
  def discard(entry) do
    outbox = entry.__struct__

    if entry.op == :create do
      chain = record_chain(entry)

      Enum.each(
        chain,
        &Ash.destroy!(&1, action: :discard, domain: domain(outbox), authorize?: false)
      )

      {:ok, %{discarded: length(chain), dropped_chain: true}}
    else
      Ash.destroy!(entry, action: :discard, domain: domain(outbox), authorize?: false)
      {:ok, %{discarded: 1, dropped_chain: false}}
    end
  end

  @doc """
  Replica wins: write the replica row over the local layer, drop the chain.

  Propagates the local-write result (M-5): on failure, returns `{:error, _}`
  and leaves the chain in place — the only record of the disagreement would
  otherwise be destroyed while the local layer still holds the un-discarded
  value.
  """
  @spec discard_local(Ash.Resource.record()) :: :ok | {:error, term()}
  def discard_local(entry) do
    host = host(entry)
    local = LocalOutbox.local_layer(host)

    result =
      case Target.read_pk(host, last_target(host), entry.record_pk) do
        {:ok, nil} ->
          # gone remotely — remove locally too
          record = Snapshot.load(host, entry.record_pk)
          Backfill.destroy_record(local, host, record, backfill_opts(host))

        {:ok, remote} ->
          Backfill.upsert_record(local, host, remote, backfill_opts(host))
      end

    case normalize(result) do
      :ok ->
        drop_chain(entry)
        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc "Re-flush as a blind PK-upsert/destroy, ignoring base_image (LWW for this entry)."
  @spec force(Ash.Resource.record()) :: :ok | {:error, term()}
  def force(entry) do
    host = host(entry)
    outbox = entry.__struct__
    record = Target.record_from_entry(host, entry)

    result =
      if entry.op == :destroy do
        Target.destroy(host, entry.target, record)
      else
        Target.upsert(host, entry.target, record)
      end

    case normalize(result) do
      :ok ->
        Ash.destroy!(entry, action: :discard, domain: domain(outbox), authorize?: false)
        kick_next(entry)
        :ok

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  The app resolved the conflict into a NEW write: apply `changeset` through the
  full LocalOutbox write path (fresh entries), then drop exactly the OLD
  parked chain.

  Sequence is load-bearing (M-1): capture the parked chain's entries FIRST —
  the apply below creates fresh entries sharing the same
  `(resource, record_pk, target)` key, so a key-scoped chain lookup taken
  AFTER applying would also catch (and destroy) those fresh `:pending`
  entries, losing the very replication `rebase/2` exists to preserve. Only
  destroy the entries captured before the apply ran.

  Failure postures (invariant 1, both halves): if the apply raises or errors,
  nothing below runs — the parked chain is untouched and the caller holds the
  error. If cleanup of the captured chain fails, nothing is destroyed (it runs
  in one outbox-repo transaction) — the resolution is applied locally and its
  fresh entries exist, held `:blocked` behind the still-parked head; the
  caller gets a `RebaseCleanupError` naming that head so an operator can run
  the recovery (`discard/1`) directly.
  """
  @spec rebase(Ash.Resource.record(), Ash.Changeset.t()) ::
          {:ok, Ash.Resource.record()} | {:error, term()}
  def rebase(entry, changeset) do
    outbox = entry.__struct__
    captured_chain = record_chain(entry)

    result =
      case changeset.action_type do
        :create -> Ash.create!(changeset)
        :update -> Ash.update!(changeset)
        :destroy -> Ash.destroy!(changeset)
      end

    case destroy_captured_chain(outbox, captured_chain, entry) do
      :ok ->
        kick_next(entry)
        {:ok, result}

      {:error, _} = error ->
        error
    end
  end

  # Destroys exactly the chain captured before `rebase/2` applied its
  # resolution changeset — never a fresh key-scoped `drop_chain/1`, which
  # cannot distinguish the old chain from the apply's own fresh entries (the
  # M-1 bug). All-or-nothing inside one outbox-repo transaction: an
  # `Ash.destroy!` raise inside `Ash.DataLayer.transaction` rolls back
  # (destroying nothing) and re-raises, which this rescues into a structured
  # error. Destroys newest-seq-first (parked-head-last): on a repo-less
  # outbox (no transaction, the defensive fallback only), a partial failure
  # then still leaves the parked head — the blocker and the evidence — intact.
  defp destroy_captured_chain(_outbox, [], _entry), do: :ok

  defp destroy_captured_chain(outbox, captured_chain, entry) do
    domain = domain(outbox)
    ordered = Enum.sort_by(captured_chain, & &1.seq, :desc)

    Ash.DataLayer.transaction(outbox, fn ->
      Enum.each(
        ordered,
        &Ash.destroy!(&1, action: :discard, domain: domain, authorize?: false)
      )
    end)

    :ok
  rescue
    error ->
      head_seq = captured_chain |> Enum.map(& &1.seq) |> Enum.min(fn -> entry.seq end)

      {:error,
       %AshMultiDatalayer.Orchestrator.LocalOutbox.RebaseCleanupError{
         cause: error,
         resource: entry.resource,
         record_pk: entry.record_pk,
         target: entry.target,
         head_seq: head_seq
       }}
  end

  # --- sync control ------------------------------------------------------

  @doc "Pause the outbox flush queue for a host resource."
  @spec pause_sync(Ash.Resource.t()) :: :ok
  def pause_sync(host_resource) do
    Oban.pause_queue(instance(host_resource), queue: queue(host_resource))
  end

  @doc "Resume the outbox flush queue and kick the pending backlog immediately."
  @spec resume_sync(Ash.Resource.t()) :: :ok
  def resume_sync(host_resource) do
    :ok = Oban.resume_queue(instance(host_resource), queue: queue(host_resource))
    # Kick the backlog so it drains without waiting for the next sweep tick.
    outbox = outbox(host_resource)
    for entry <- pending(host_resource), do: Enqueue.flush(outbox, entry)
    :ok
  end

  @doc "Whether the outbox flush queue for a host resource is currently paused."
  @spec sync_paused?(Ash.Resource.t()) :: boolean()
  def sync_paused?(host_resource) do
    case Oban.check_queue(instance(host_resource), queue: queue(host_resource)) do
      %{paused: paused} -> paused
      _ -> false
    end
  rescue
    _ -> false
  end

  # --- inbound: refresh + hydration -------------------------------------

  @doc """
  Read matching rows from the last `write_order` layer and PK-upsert them into
  the local layer; records present locally but absent remotely within scope are
  deleted locally. **Skips any PK whose outbox chain is non-empty** (the
  dirty-chain rule) — its convergence path is the outbound flush.
  """
  @spec refresh(Ash.Resource.t(), :all | map(), term()) :: %{
          refreshed: non_neg_integer(),
          deleted: non_neg_integer(),
          skipped_dirty: [map()]
        }
  def refresh(host_resource, scope, tenant \\ nil) do
    local = LocalOutbox.local_layer(host_resource)
    target = last_target(host_resource)
    opts = backfill_opts(host_resource, tenant)

    {remote_rows, do_delete?} = remote_scope(host_resource, target, scope, tenant)

    {refreshed, skipped} =
      Enum.reduce(remote_rows, {0, []}, fn row, {n, skipped} ->
        pk = Snapshot.record_pk(host_resource, row)

        if dirty?(host_resource, pk, tenant) do
          {n, [pk | skipped]}
        else
          :ok = Backfill.upsert_record(local, host_resource, row, opts) |> normalize_backfill()
          {n + 1, skipped}
        end
      end)

    deleted =
      cond do
        # `:all` scope is authoritative over the whole set — reconcile removals.
        do_delete? ->
          reconcile_deletes(host_resource, local, remote_rows, tenant, opts)

        # A single-PK refresh whose remote row is GONE mirrors a peer's destroy:
        # remove it locally (unless the PK is dirty — our own unflushed write wins).
        # Without this, an inbound destroy notification (handle_external_change →
        # refresh(pk)) left the deleted row lingering on other online clients.
        is_map(scope) and remote_rows == [] and not dirty?(host_resource, scope, tenant) ->
          delete_local_pk(host_resource, local, scope, tenant, opts)

        true ->
          0
      end

    %{refreshed: refreshed, deleted: deleted, skipped_dirty: Enum.reverse(skipped)}
  end

  # Destroy a single locally-held row by primary key (a peer's destroy arrived via
  # a per-record notification, so there is no remote row to compare against).
  defp delete_local_pk(host_resource, local, pk, tenant, opts) do
    case Target.read_pk(host_resource, hd(read_order(host_resource)), pk, tenant: tenant) do
      {:ok, nil} ->
        0

      {:ok, local_row} ->
        :ok = normalize_backfill(Backfill.destroy_record(local, host_resource, local_row, opts))
        1
    end
  end

  @doc "Full hydration: guarded by an empty outbox, then `refresh(:all)`."
  @spec hydrate(Ash.Resource.t(), term()) :: {:ok, map()} | {:error, :outbox_not_empty}
  def hydrate(host_resource, tenant \\ nil) do
    if outbox_nonempty?(host_resource, tenant) do
      {:error, :outbox_not_empty}
    else
      {:ok, refresh(host_resource, :all, tenant)}
    end
  end

  # --- notification bridge ----------------------------------------------

  @doc "Routes an inbound change notification to a per-record `refresh/3`."
  @spec handle_external_change(Ash.Resource.t(), Ash.Notifier.Notification.t()) :: :ok
  def handle_external_change(host_resource, %{data: data}) when not is_nil(data) do
    pk = Snapshot.record_pk(host_resource, data)
    _ = refresh(host_resource, pk, tenant_of(data))
    :ok
  end

  def handle_external_change(_host_resource, _notification), do: :ok

  @doc "Routes a gap notification (missed/unreliable delivery) to a full `refresh(:all)`."
  @spec handle_external_gap(Ash.Resource.t(), term()) :: :ok
  def handle_external_gap(host_resource, tenant) do
    _ = refresh(host_resource, :all, tenant)
    :ok
  end

  # --- boot-time hydration ----------------------------------------------

  @doc "Boot-time hydration child specs for every `:if_empty`/`:on_start` resource."
  @spec child_specs([Ash.Resource.t()]) :: [Supervisor.child_spec()]
  def child_specs(resources) do
    to_hydrate = Enum.filter(resources, &(LocalOutbox.hydrate_mode(&1) in [:if_empty, :on_start]))

    for resource <- to_hydrate do
      Supervisor.child_spec(
        {Task, fn -> boot_hydrate(resource) end},
        id: {__MODULE__, :hydrate, resource}
      )
    end
  end

  defp boot_hydrate(resource) do
    case LocalOutbox.hydrate_mode(resource) do
      :on_start -> refresh(resource, :all)
      :if_empty -> hydrate(resource)
      _ -> :ok
    end

    :ok
  rescue
    # Mirrors ExternalChange's warn-then-swallow contract: a failed boot
    # hydration must not crash the supervision tree (a stale/empty local
    # authority self-heals on the next refresh/gap sweep), but it must not be
    # *silent* either — an operator needs to know the local layer booted
    # without its seed data.
    error ->
      Logger.warning(
        "ash_multi_datalayer: boot hydration for #{inspect(resource)} failed and was " <>
          "skipped (the local layer boots without its seed data; self-heals on the next " <>
          "refresh/hydrate): #{Exception.message(error)}\n" <>
          Exception.format_stacktrace(__STACKTRACE__)
      )

      :ok
  end

  # --- internals ---------------------------------------------------------

  defp remote_scope(host_resource, target, :all, tenant) do
    {:ok, rows} = Target.read_all(host_resource, target, tenant: tenant)
    {rows, true}
  end

  defp remote_scope(host_resource, target, pk, tenant) when is_map(pk) do
    case Target.read_pk(host_resource, target, pk, tenant: tenant) do
      {:ok, nil} -> {[], false}
      {:ok, row} -> {[row], false}
    end
  end

  defp reconcile_deletes(host_resource, local, remote_rows, tenant, opts) do
    remote_pks = MapSet.new(remote_rows, &Snapshot.record_pk(host_resource, &1))

    {:ok, local_rows} =
      Target.read_all(host_resource, hd(read_order(host_resource)), tenant: tenant)

    local_rows
    |> Enum.reject(fn row ->
      pk = Snapshot.record_pk(host_resource, row)
      MapSet.member?(remote_pks, pk) or dirty?(host_resource, pk, tenant)
    end)
    |> Enum.reduce(0, fn row, n ->
      :ok = Backfill.destroy_record(local, host_resource, row, opts) |> normalize_backfill()
      n + 1
    end)
  end

  # A PK is dirty if it has any UNFLUSHED (pending-or-parked) outbox entry (any
  # target). `:synced` entries are already applied and never block a refresh.
  defp dirty?(host_resource, pk, tenant) do
    host_resource
    |> outbox()
    |> base_query(host_resource, tenant)
    |> Ash.Query.filter(record_pk == ^pk and state != :synced)
    |> Ash.Query.limit(1)
    |> read()
    |> Enum.any?()
  end

  defp outbox_nonempty?(host_resource, tenant) do
    host_resource
    |> outbox()
    |> base_query(host_resource, tenant)
    |> Ash.Query.filter(state != :synced)
    |> Ash.Query.limit(1)
    |> read()
    |> Enum.any?()
  end

  # The unflushed (pending-or-parked) entries of a record's chain — synced ones
  # are already applied and must not be re-dropped.
  defp record_chain(entry) do
    entry.__struct__
    |> Ash.Query.for_read(
      :for_record,
      %{resource: entry.resource, record_pk: entry.record_pk, target: entry.target},
      domain: domain(entry.__struct__)
    )
    |> Ash.Query.filter(state != :synced)
    |> read()
  end

  defp drop_chain(entry) do
    outbox = entry.__struct__

    Enum.each(
      record_chain(entry),
      &Ash.destroy!(&1, action: :discard, domain: domain(outbox), authorize?: false)
    )
  end

  defp kick_next(entry) do
    outbox = entry.__struct__

    outbox
    |> Ash.Query.for_read(
      :for_record,
      %{resource: entry.resource, record_pk: entry.record_pk, target: entry.target},
      domain: domain(outbox)
    )
    |> Ash.Query.filter(state == :pending)
    |> Ash.Query.sort(seq: :asc)
    |> Ash.Query.limit(1)
    |> read()
    |> case do
      [next | _] -> Enqueue.flush(outbox, next)
      [] -> :ok
    end
  end

  defp base_query(query, host_resource, tenant) do
    key = Atom.to_string(host_resource)
    q = Ash.Query.filter(query, resource == ^key)
    if tenant, do: Ash.Query.filter(q, tenant == ^to_string(tenant)), else: q
  end

  defp read(query), do: Ash.read!(query, authorize?: false)

  defp outbox(host_resource), do: LocalOutbox.outbox_resource(host_resource)
  defp domain(resource), do: Ash.Resource.Info.domain(resource)
  defp host(entry) do
    outbox = entry.__struct__

    case AshMultiDatalayer.Orchestrator.LocalOutbox.HostResolver.resolve(
           outbox,
           entry.resource
         ) do
      {:ok, host} ->
        host

      :error ->
        raise "unresolvable LocalOutbox host resource for outbox entry " <>
                "(resource: #{inspect(entry.resource)}) — this app no longer defines it"
    end
  end
  defp queue(host_resource), do: SyncInfo.queue(outbox(host_resource))
  defp instance(host_resource), do: SyncInfo.oban_instance(outbox(host_resource))
  defp read_order(host_resource), do: AshMultiDatalayer.DataLayer.Info.read_order(host_resource)

  defp last_target(host_resource),
    do: List.last(AshMultiDatalayer.DataLayer.Info.write_order(host_resource))

  defp backfill_opts(host_resource, tenant \\ nil) do
    [tenant: tenant, domain: Ash.Resource.Info.domain(host_resource)]
  end

  defp tenant_of(%{__metadata__: %{tenant: tenant}}), do: tenant
  defp tenant_of(_), do: nil

  defp normalize(:ok), do: :ok
  defp normalize({:ok, _}), do: :ok
  defp normalize({:error, error}), do: {:error, error}

  defp normalize_backfill(:ok), do: :ok
  defp normalize_backfill({:ok, _}), do: :ok

  defp normalize_backfill({:error, _layer, reason}),
    do: raise("backfill failed: #{inspect(reason)}")

  defp normalize_backfill({:error, reason}), do: raise("backfill failed: #{inspect(reason)}")

  defp now_ms, do: System.monotonic_time(:millisecond)
end
