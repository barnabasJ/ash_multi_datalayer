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
  """

  alias AshMultiDatalayer.Orchestrator.LocalOutbox
  alias AshMultiDatalayer.Orchestrator.LocalOutbox.Snapshot
  alias AshMultiDatalayer.Sync.Enqueue

  @doc false
  def run(resource, changeset, op) do
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
        # Post-commit kick — after the write is durable; a lost kick is recovered
        # by the MDL sweeper (rows are the truth, jobs are ephemeral pointers).
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
    Ash.DataLayer.run_upsert(local, resource, changeset, keys, identity)
  end

  # --- outbox enqueue (one entry per target) ----------------------------

  defp enqueue_entries(outbox, resource, changeset, op, record, targets, write_ref) do
    domain = Ash.Resource.Info.domain(outbox)
    op_atom = op_atom(op)
    record_pk = Snapshot.record_pk(resource, record)
    payload = payload(op_atom, resource, record)
    base_image = base_image(op_atom, resource, changeset)
    tenant = stringify(changeset.tenant)

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

  defp stringify(nil), do: nil
  defp stringify(tenant) when is_binary(tenant), do: tenant
  defp stringify(tenant), do: to_string(tenant)

  # --- co-commit transaction --------------------------------------------

  defp in_transaction(nil, fun), do: fun.()

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
  # module).
  defp co_commit_repo(resource, local_layer, outbox) do
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
