defmodule AshMultiDatalayer.Orchestrator.LocalOutbox.Api do
  @moduledoc """
  The LocalOutbox public surface: awaitable handles, queryable outbox state,
  resolution verbs, sync pause/resume, inbound `refresh/3` + hydration, and the
  notification-bridge callbacks. Re-exported from
  `AshMultiDatalayer.Orchestrator.LocalOutbox`.
  """
  require Ash.Query

  alias AshMultiDatalayer.Backfill
  alias AshMultiDatalayer.Orchestrator.LocalOutbox
  alias AshMultiDatalayer.Orchestrator.LocalOutbox.{Snapshot, Target}
  alias AshMultiDatalayer.Sync.Enqueue
  alias AshMultiDatalayer.Sync.Info, as: SyncInfo

  # --- queryable state ---------------------------------------------------

  @doc "Pending entries for a host resource (optionally scoped to a tenant)."
  def pending(host_resource, tenant \\ nil) do
    host_resource
    |> outbox()
    |> base_query(host_resource, tenant)
    |> Ash.Query.filter(state == :pending)
    |> Ash.Query.sort(seq: :asc)
    |> read()
  end

  @doc "Parked entries for a host resource (optionally scoped to a tenant)."
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

  @doc "Replica wins: write the replica row over the local layer, drop the chain."
  def discard_local(entry) do
    host = host(entry)
    local = LocalOutbox.local_layer(host)

    case Target.read_pk(host, last_target(host), entry.record_pk) do
      {:ok, nil} ->
        # gone remotely — remove locally too
        record = Snapshot.load(host, entry.record_pk)
        Backfill.destroy_record(local, host, record, backfill_opts(host))

      {:ok, remote} ->
        Backfill.upsert_record(local, host, remote, backfill_opts(host))
    end

    drop_chain(entry)
    :ok
  end

  @doc "Re-flush as a blind PK-upsert/destroy, ignoring base_image (LWW for this entry)."
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
  full LocalOutbox write path (fresh entries), then drop the parked chain.
  """
  def rebase(entry, changeset) do
    result =
      case changeset.action_type do
        :create -> Ash.create!(changeset)
        :update -> Ash.update!(changeset)
        :destroy -> Ash.destroy!(changeset)
      end

    drop_chain(entry)
    {:ok, result}
  end

  # --- sync control ------------------------------------------------------

  def pause_sync(host_resource) do
    Oban.pause_queue(instance(host_resource), queue: queue(host_resource))
  end

  def resume_sync(host_resource) do
    :ok = Oban.resume_queue(instance(host_resource), queue: queue(host_resource))
    # Kick the backlog so it drains without waiting for the next sweep tick.
    outbox = outbox(host_resource)
    for entry <- pending(host_resource), do: Enqueue.flush(outbox, entry)
    :ok
  end

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
  def hydrate(host_resource, tenant \\ nil) do
    if outbox_nonempty?(host_resource, tenant) do
      {:error, :outbox_not_empty}
    else
      {:ok, refresh(host_resource, :all, tenant)}
    end
  end

  # --- notification bridge ----------------------------------------------

  def handle_external_change(host_resource, %{data: data}) when not is_nil(data) do
    pk = Snapshot.record_pk(host_resource, data)
    _ = refresh(host_resource, pk, tenant_of(data))
    :ok
  end

  def handle_external_change(_host_resource, _notification), do: :ok

  def handle_external_gap(host_resource, tenant) do
    _ = refresh(host_resource, :all, tenant)
    :ok
  end

  # --- boot-time hydration ----------------------------------------------

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
  rescue
    _ -> :ok
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
  defp host(entry), do: String.to_existing_atom(entry.resource)
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
