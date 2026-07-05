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

  require Ash.Query

  alias AshMultiDatalayer.Orchestrator.LocalOutbox
  alias AshMultiDatalayer.Orchestrator.LocalOutbox.Snapshot
  alias AshMultiDatalayer.Sync.Enqueue

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
  # failure fails the whole action with nothing committed. No outbox entry — the
  # caller gets a hard server-durability guarantee for exactly this write.
  defp write_through?(changeset) do
    changeset.context |> Map.get(:multi_datalayer, %{}) |> Map.get(:write_through) == true
  end

  defp write_through(resource, changeset, op) do
    local = LocalOutbox.local_layer(resource)
    op_atom = op_atom(op)
    record_pk = Snapshot.record_pk(resource, changeset.data)

    with :ok <- drain_chain_inline(resource, record_pk),
         {:ok, record} <- local_write(local, resource, changeset, op),
         :ok <- push_all_targets(resource, op_atom, record) do
      finalize_write_through(op, record)
    end
  end

  defp drain_chain_inline(resource, record_pk) do
    outbox = LocalOutbox.outbox_resource(resource)
    key = Atom.to_string(resource)

    outbox
    |> Ash.Query.for_read(:read, %{}, domain: Ash.Resource.Info.domain(outbox))
    |> Ash.Query.filter(resource == ^key and record_pk == ^record_pk and state != :synced)
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

        {:conflict, _} = c ->
          {:halt, {:error, c}}

        {:error, _} = e ->
          {:halt, e}
      end
    end)
  end

  defp push_all_targets(resource, op_atom, record) do
    Enum.reduce_while(LocalOutbox.targets(resource), :ok, fn target, :ok ->
      result =
        if op_atom == :destroy do
          normalize(
            AshMultiDatalayer.Orchestrator.LocalOutbox.Target.destroy(resource, target, record)
          )
        else
          normalize(
            AshMultiDatalayer.Orchestrator.LocalOutbox.Target.upsert(resource, target, record)
          )
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
