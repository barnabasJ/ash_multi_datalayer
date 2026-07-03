defmodule AshMultiDatalayer.Coverage do
  @moduledoc """
  The coverage ledger: per-resource, tenant-partitioned records of which
  filters have been fully materialised into earlier layers.

  Storage is a named public ETS table per resource, owned by
  `AshMultiDatalayer.Coverage.TableOwner` and created lazily on first use.
  Rows are keyed `{tenant, entry_id}`; `nil` tenants use the `:__global__`
  sentinel so untagged entries form a distinct partition.
  """

  require Logger

  alias AshMultiDatalayer.Coverage.TableOwner

  @global_tenant :__global__

  @doc "The ledger partition key for a tenant (`nil` -> `:__global__`)."
  @spec tenant_key(term()) :: term()
  def tenant_key(nil), do: @global_tenant
  def tenant_key(tenant), do: tenant

  @doc """
  Ensures the resource's ledger table exists, lazily starting its owner.

  Returns `:ok`, or `{:error, :unavailable}` when `AshMultiDatalayer.Supervisor`
  is not running in the host application — in that case callers degrade to
  kill-switched behaviour (a performance bug, never a correctness bug), and a
  warning is logged once per node.
  """
  @spec ensure_table(module()) :: :ok | {:error, :unavailable}
  def ensure_table(resource) do
    if :ets.whereis(TableOwner.table_name(resource)) != :undefined do
      :ok
    else
      start_owner(resource)
    end
  end

  @doc "All ledger entries for a resource+tenant."
  @spec entries(module(), term()) :: [term()]
  def entries(resource, tenant) do
    table = TableOwner.table_name(resource)
    key = tenant_key(tenant)

    :ets.select(table, [{{{key, :_}, :"$1"}, [], [:"$1"]}])
  rescue
    ArgumentError -> []
  end

  @doc "Inserts a ledger entry (keyed by `entry.id`) for a resource+tenant."
  @spec insert(module(), term(), %{id: term()}) :: :ok
  def insert(resource, tenant, entry) do
    table = TableOwner.table_name(resource)
    true = :ets.insert(table, {{tenant_key(tenant), entry.id}, entry})
    :ok
  end

  @doc "Drops a single entry by id. Missing entries are a no-op."
  @spec drop(module(), term(), term()) :: :ok
  def drop(resource, tenant, entry_id) do
    table = TableOwner.table_name(resource)
    true = :ets.delete(table, {tenant_key(tenant), entry_id})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Clears the resource's entire ledger (all tenants)."
  @spec reset(module()) :: :ok
  def reset(resource) do
    table = TableOwner.table_name(resource)
    true = :ets.delete_all_objects(table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp start_owner(resource) do
    case DynamicSupervisor.start_child(
           AshMultiDatalayer.TableSupervisor,
           {TableOwner, resource}
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> unavailable(resource, reason)
    end
  catch
    :exit, {:noproc, _} -> unavailable(resource, :supervisor_not_running)
  end

  defp unavailable(resource, reason) do
    warn_once(resource, reason)
    {:error, :unavailable}
  end

  defp warn_once(resource, reason) do
    key = {:ash_multi_datalayer, :supervisor_warning_logged}

    unless :persistent_term.get(key, false) do
      :persistent_term.put(key, true)

      Logger.warning("""
      ash_multi_datalayer could not start the coverage-ledger owner for \
      #{inspect(resource)} (#{inspect(reason)}). Reads will fall through to \
      the source of truth without caching. Add AshMultiDatalayer.Supervisor \
      to your application's supervision tree.
      """)
    end
  end
end
