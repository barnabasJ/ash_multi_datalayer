defmodule AshMultiDatalayer.Orchestrator.LocalOutbox.Write do
  @moduledoc """
  The LocalOutbox write path (RFC "Write path"):

    1. synchronous authoritative write to the local layer (fail-fast);
    2. one outbox entry per replication target, sharing a `write_ref`;
    3. return `{:ok, record}` with `record.__metadata__.outbox_ref` set;
    4. post-commit: kick a flush job per entry.

  Steps 1–2 run in **one `Repo.transaction/1`** when the local layer and the
  outbox resource share an Ecto repo (the SQLite client stack) — the co-commit
  that makes the durability invariant a construction. The predicate is repo
  identity, never `can?(:transact)` (ash_sqlite hardcodes that false).

  `write_through: true` context is a DIFFERENT, synchronous write path (see
  `write_through/3` below): every replica target is written FIRST, and the
  local layer only commits once every target has durably accepted the write —
  a replica failure fails the whole action with the local layer untouched
  (M-2). No outbox entry — the caller gets a hard server-durability guarantee
  for exactly this write.
  """

  require Ash.Query

  alias AshMultiDatalayer.Orchestrator.LocalOutbox
  alias AshMultiDatalayer.Orchestrator.LocalOutbox.{Snapshot, Target}
  alias AshMultiDatalayer.Sync.Enqueue
  alias AshMultiDatalayer.TenantKey

  @doc false
  def run(resource, changeset, op) do
    if write_through?(changeset) do
      write_through(resource, changeset, op)
    else
      async_run(resource, changeset, op)
    end
  end

  # --- write_through: synchronous "durable on the server or error" ------

  # `write_through: true` context — the per-action kill-switch write path (RFC
  # "Targeted writes"): drain the record's pending PK chain inline, then write
  # every replica target synchronously *first*, then the local layer; a replica
  # failure fails the whole action with nothing committed (M-2 — this order is
  # the moduledoc's spec; the local layer must never hold a value no target
  # accepted). No outbox entry — the caller gets a hard server-durability
  # guarantee for exactly this write.
  defp write_through?(changeset) do
    changeset.context |> Map.get(:multi_datalayer, %{}) |> Map.get(:write_through) == true
  end

  defp write_through(resource, changeset, op) do
    local = LocalOutbox.local_layer(resource)
    op_atom = op_atom(op)
    record_pk = Snapshot.record_pk(resource, changeset.data)

    tenant = TenantKey.changeset(resource, changeset, changeset.data)

    with :ok <- drain_chain_inline(resource, record_pk, tenant),
         {:ok, record, fields} <- materialize(resource, changeset, op),
         :ok <- push_all_targets(resource, op_atom, record, fields, tenant),
         {:ok, local_record} <- local_write(local, resource, changeset, op) do
      finalize_write_through(op, local_record)
    end
  end

  defp drain_chain_inline(resource, record_pk, tenant) do
    outbox = LocalOutbox.outbox_resource(resource)
    key = Atom.to_string(resource)
    tenant_key = TenantKey.canonical(resource, tenant)

    outbox
    |> Ash.Query.for_read(:read, %{}, domain: Ash.Resource.Info.domain(outbox))
    |> Ash.Query.filter(resource == ^key and record_pk == ^record_pk and state != :synced)
    |> tenant_filter(tenant_key)
    |> Ash.Query.sort(seq: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.reduce_while(:ok, fn entry, :ok ->
      case AshMultiDatalayer.Orchestrator.LocalOutbox.Flush.push(resource, entry) do
        :ok ->
          Ash.destroy!(entry,
            action: :discard,
            domain: Ash.Resource.Info.domain(outbox),
            authorize?: false
          )

          {:cont, :ok}

        {:conflict, remote} ->
          {:halt,
           {:error,
            %AshMultiDatalayer.Orchestrator.LocalOutbox.ConflictError{remote_snapshot: remote}}}

        {:error, _} = e ->
          {:halt, e}
      end
    end)
  end

  # `tenant_key` is always B3's canonical partition string (never nil —
  # `TenantKey.canonical/2` maps a tenant-less write to the single unscoped
  # sentinel, stored/matched like any other partition) — a plain equality
  # filter, no local to_string/inspect.
  defp tenant_filter(query, tenant_key),
    do: Ash.Query.filter(query, tenant == ^to_string(tenant_key))

  # Materializes the record write_through pushes to targets — WITHOUT running
  # the local write yet (M-2's reorder: targets first, local last). A destroy
  # has no attributes to materialize; push by PK alone.
  #
  # For create/update: `Ash.Changeset.apply_attributes/1` folds
  # `changeset.attributes` onto `changeset.data` (after `set_defaults`) —
  # the arity-1/opts form; there is no form taking `data` separately. No
  # force-back of lazy defaults is needed: the Ash action pipeline already
  # calls `set_defaults(:create | :update, true)` before the data layer runs,
  # evaluating lazy defaults exactly once and `force_change_attribute`-ing the
  # result in, and every later `set_defaults` (including inside
  # `apply_attributes`) is idempotent via the `changing_attribute?` guard —
  # both the target push and the local write below see identical values.
  #
  # Guards fail closed: an atomic changeset (checked in BOTH `:atomics` and
  # `:create_atomics` — create-time atomics live only in the latter, which
  # `apply_attributes` cannot evaluate) or a `:create` whose primary key is
  # still `nil` after materialization (a genuinely DB-generated key) are
  # unsupported for write_through — say so in the error rather than silently
  # diverging.
  defp materialize(_resource, changeset, :destroy), do: {:ok, changeset.data, nil}

  defp materialize(resource, changeset, _op) do
    with :ok <- reject_atomics(changeset),
         {:ok, record} <- Ash.Changeset.apply_attributes(changeset),
         :ok <- reject_nil_create_pk(resource, changeset, record) do
      {:ok, record, push_fields(resource, changeset, record)}
    else
      {:error, %Ash.Changeset{} = invalid} -> {:error, invalid}
      {:error, _} = error -> error
    end
  end

  defp reject_atomics(changeset) do
    if changeset.atomics == [] and changeset.create_atomics in [[], %{}] do
      :ok
    else
      {:error,
       "write_through does not support atomic creates/updates — the target push is built " <>
         "from materialized attribute values (Ash.Changeset.apply_attributes/1 cannot evaluate " <>
         "an atomic expression). Use the async (outbox) write path for this action instead."}
    end
  end

  defp reject_nil_create_pk(resource, %{action_type: :create}, record) do
    nil_pk_fields =
      resource |> Ash.Resource.Info.primary_key() |> Enum.filter(&is_nil(Map.get(record, &1)))

    if nil_pk_fields == [] do
      :ok
    else
      {:error,
       "write_through create left primary key field(s) #{inspect(nil_pk_fields)} nil after " <>
         "materialization — DB-generated primary keys (and other DB-generated fields) are not " <>
         "supported for write_through creates; only Ash-level (including lazy) defaults are " <>
         "pre-materialized. Use the async (outbox) write path for this resource/action instead."}
    end
  end

  defp reject_nil_create_pk(_resource, _changeset, _record), do: :ok

  # loaded/materialized fields ∪ explicitly changed fields ∪ the primary key —
  # never `%Ash.NotLoaded{}`. On an update built from a partially-selected
  # record, `apply_attributes` overlays changes onto `changeset.data`, so
  # untouched UNselected fields remain NotLoaded; the push must never carry
  # those (`Backfill.upsert_record` defaults to ALL resource attributes with
  # no `:fields` option, which would write NotLoaded garbage to the target).
  defp push_fields(resource, changeset, record) do
    pk = MapSet.new(Ash.Resource.Info.primary_key(resource))
    changed = MapSet.new(Map.keys(changeset.attributes))

    loaded =
      resource
      |> Ash.Resource.Info.attributes()
      |> Enum.map(& &1.name)
      |> Enum.filter(&loaded?(Map.get(record, &1)))
      |> MapSet.new()

    pk |> MapSet.union(changed) |> MapSet.union(loaded) |> Enum.to_list()
  end

  defp loaded?(%Ash.NotLoaded{}), do: false
  defp loaded?(_), do: true

  defp push_all_targets(resource, op_atom, record, fields, tenant) do
    Enum.reduce_while(LocalOutbox.targets(resource), :ok, fn target, :ok ->
      result =
        if op_atom == :destroy do
          normalize(Target.destroy(resource, target, record, tenant: tenant))
        else
          normalize(Target.upsert(resource, target, record, fields: fields, tenant: tenant))
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, _} = e -> {:halt, e}
      end
    end)
  end

  defp finalize_write_through(:destroy, _record), do: :ok
  defp finalize_write_through(_op, record), do: {:ok, record}

  defp normalize(:ok), do: :ok
  defp normalize({:ok, _}), do: :ok
  defp normalize({:error, :no_rollback, error}), do: {:error, error}
  defp normalize({:error, error}), do: {:error, error}

  # --- async (default) write path ---------------------------------------

  defp async_run(resource, changeset, op) do
    local = LocalOutbox.local_layer(resource)
    outbox = LocalOutbox.outbox_resource(resource)
    targets = LocalOutbox.targets(resource)
    write_ref = Ash.UUID.generate()
    repo = co_commit_repo(resource, local, outbox)

    committed =
      in_transaction(repo, fn ->
        with {:ok, record} <- local_write(local, resource, changeset, op) do
          entries = enqueue_entries(outbox, resource, changeset, op, record, targets, write_ref)
          {:ok, record, entries}
        end
      end)

    case committed do
      {:ok, record, entries} ->
        # Post-commit kick — after the write is durable. Rows are the truth,
        # jobs are ephemeral pointers: a lost kick leaves the entry pending
        # until the next kick reaches its host chain (a later write, retry/1,
        # or resume_sync/1) — there is no background sweeper.
        Enum.each(entries, &Enqueue.flush(outbox, &1))
        finalize(op, record, write_ref)

      {:error, error} ->
        {:error, error}
    end
  end

  # --- authoritative local write ----------------------------------------

  defp local_write(local, resource, changeset, :create), do: local.create(resource, changeset)
  defp local_write(local, resource, changeset, :update), do: local.update(resource, changeset)

  defp local_write(local, resource, changeset, :destroy) do
    case local.destroy(resource, changeset) do
      :ok -> {:ok, changeset.data}
      other -> other
    end
  end

  defp local_write(local, resource, changeset, {:upsert, keys, identity}) do
    changeset = %{changeset | tenant: changeset.to_tenant}

    if Code.ensure_loaded?(local) and function_exported?(local, :upsert, 4) do
      Ash.DataLayer.run_upsert(local, resource, changeset, keys, identity)
    else
      Ash.DataLayer.run_upsert(local, resource, changeset, keys)
    end
    |> normalize_upsert()
  end

  # --- outbox enqueue (one entry per target) ----------------------------

  defp enqueue_entries(outbox, resource, changeset, op, record, targets, write_ref) do
    domain = Ash.Resource.Info.domain(outbox)
    op_atom = op_atom(op)
    record_pk = Snapshot.record_pk(resource, record)
    payload = payload(op_atom, resource, record)
    base_image = base_image(op_atom, resource, changeset)

    tenant =
      resource
      |> TenantKey.changeset(changeset, record)
      |> then(&TenantKey.canonical(resource, &1))
      |> to_string()

    for target <- targets do
      outbox
      |> Ash.Changeset.for_create(
        :enqueue,
        %{
          write_ref: write_ref,
          resource: Atom.to_string(resource),
          tenant: tenant,
          record_pk: record_pk,
          op: op_atom,
          payload: payload,
          base_image: base_image,
          target: target
        },
        domain: domain
      )
      |> Ash.create!(authorize?: false)
    end
  end

  defp op_atom(:create), do: :create
  defp op_atom(:update), do: :update
  defp op_atom(:destroy), do: :destroy
  defp op_atom({:upsert, _keys, _identity}), do: :upsert

  # Destroy replicates by primary key; no payload needed.
  defp payload(:destroy, _resource, _record), do: nil
  defp payload(_op, resource, record), do: Snapshot.dump(resource, record)

  # base_image (the before-state) drives stale-check conflict detection.
  defp base_image(op, resource, changeset) when op in [:update, :destroy],
    do: Snapshot.dump(resource, changeset.data)

  defp base_image(_op, _resource, _changeset), do: nil

  defp normalize_upsert({:error, :no_rollback, reason}), do: {:error, reason}
  defp normalize_upsert(other), do: other

  # --- co-commit transaction --------------------------------------------

  # No co-commit repo (belt-and-suspenders — `validate_opts` rejects this
  # config at compile time, but a direct/test call to `Write.run/3` can still
  # reach here): the local write and the enqueue are NOT atomic, so an
  # enqueue failure would otherwise raise past an already-committed local
  # write. Rescue it into the same `{:error, _}` shape a co-committed failure
  # returns — the local write still stands (unrecoverable without a repo),
  # but the caller gets a data-layer error instead of an uncaught raise.
  defp in_transaction(nil, fun) do
    fun.()
  rescue
    error -> {:error, error}
  end

  defp in_transaction(repo, fun) do
    case repo.transaction(fn ->
           case fun.() do
             {:ok, record, entries} -> {record, entries}
             {:error, error} -> repo.rollback(error)
           end
         end) do
      {:ok, {record, entries}} -> {:ok, record, entries}
      {:error, error} -> {:error, error}
    end
  end

  # Same Ecto repo for the local layer and the outbox → co-commit. Detected via
  # `<Layer>.Info.repo/2`, the convention ash_sqlite/ash_postgres share (keeps the
  # shell data-layer agnostic — the strategy asks the layer, not a hardcoded SQL
  # module). Public: `LocalOutbox.validate_opts/2` (A1-3) reuses this exact
  # resolvability check at compile time to reject a config with no co-commit
  # repo, instead of only discovering it at the first async write.
  @doc false
  def co_commit_repo(resource, local_layer, outbox) do
    outbox_layer = Ash.DataLayer.data_layer(outbox)
    local_repo = repo_of(local_layer, resource)
    outbox_repo = repo_of(outbox_layer, outbox)

    if not is_nil(local_repo) and local_repo == outbox_repo, do: local_repo
  end

  defp repo_of(layer, resource) do
    Module.concat(layer, Info).repo(resource, :mutate)
  rescue
    _ -> nil
  end

  # --- return value ------------------------------------------------------

  defp finalize(:destroy, _record, _write_ref), do: :ok

  defp finalize(_op, record, write_ref) do
    metadata = Map.put(record.__metadata__ || %{}, :outbox_ref, write_ref)
    {:ok, %{record | __metadata__: metadata}}
  end
end
