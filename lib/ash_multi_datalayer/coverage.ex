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

  alias AshMultiDatalayer.Coverage.{Entry, Implication, Normaliser, TableOwner}
  alias AshMultiDatalayer.DataLayer.Info
  alias AshMultiDatalayer.DataLayer.Query
  alias AshMultiDatalayer.Telemetry

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

  @doc """
  Whether a query's coverage may be recorded (and its results backfilled).

  Truncated or computed result sets can't prove complete coverage of a
  filter: queries with `limit`, a non-zero `offset`, `distinct`,
  `distinct_sort`, a `lock`, aggregates, or calculations are never recorded
  — recording one would later serve incomplete results as a cache hit.
  Sort does not affect set membership and is fine.
  """
  @spec recordable?(Query.t() | struct()) :: boolean()
  def recordable?(%Query{} = query) do
    is_nil(query.limit) and
      query.offset in [nil, 0] and
      query.distinct in [nil, []] and
      query.distinct_sort in [nil, []] and
      is_nil(query.lock) and
      query.aggregates == [] and
      query.calculations == []
  end

  @doc """
  Looks for a recorded filter that provably covers the query.

  A hit requires an entry whose normalised filter is implied by the probe's
  (probe ⊆ cached) **and** whose `loaded_fields` are a superset of the
  fields the query needs. Returns `{:ok, entry}` (bumping its LRU
  timestamp) or `{:miss, reason}` with reason one of `:solver_unsupported`,
  `:no_coverage_entry`, `:fields_insufficient`, or `:ledger_unavailable`.
  """
  @spec covers?(module(), term(), Query.t() | struct()) ::
          {:ok, Entry.t()} | {:miss, atom()}
  def covers?(resource, tenant, %Query{} = query) do
    case ensure_table(resource) do
      :ok ->
        probe = Normaliser.normalise(query.filter, resource)

        if probe.opaque? do
          {:miss, :solver_unsupported}
        else
          find_covering_entry(resource, tenant, probe, needed_fields(query, resource))
        end

      {:error, :unavailable} ->
        {:miss, :ledger_unavailable}
    end
  end

  defp find_covering_entry(resource, tenant, probe, needed_fields) do
    entries = entries(resource, tenant)

    implying = Enum.filter(entries, &Implication.implies?(probe, &1.normalised))

    case Enum.find(implying, &MapSet.subset?(needed_fields, &1.loaded_fields)) do
      %Entry{} = entry ->
        touch(resource, tenant, entry)
        {:ok, entry}

      nil when implying != [] ->
        {:miss, :fields_insufficient}

      nil ->
        {:miss, :no_coverage_entry}
    end
  end

  @doc """
  Records that the query's filter has been fully materialised into the
  earlier read layers. Deduplicates by the normalised filter form; opaque
  and non-recordable queries are never recorded.

  Returns `:ok` when a (new or pre-existing) entry covers the filter,
  `:skipped` otherwise.
  """
  @spec record(module(), term(), Query.t() | struct()) :: :ok | :skipped
  def record(resource, tenant, %Query{} = query) do
    normalised = Normaliser.normalise(query.filter, resource)

    with true <- recordable?(query),
         false <- normalised.opaque?,
         :ok <- ensure_table(resource) do
      fingerprint = dedupe_key(normalised)

      cond do
        Enum.any?(entries(resource, tenant), &(&1.fingerprint == fingerprint)) ->
          :ok

        enforce_cap(resource, tenant) == :full ->
          :skipped

        true ->
          entry = %Entry{
            id: make_ref(),
            tenant: tenant_key(tenant),
            filter: query.filter,
            normalised: normalised,
            fingerprint: fingerprint,
            loaded_fields: needed_fields(query, resource),
            loaded_at: System.monotonic_time()
          }

          insert(resource, tenant, entry)
      end
    else
      _ -> :skipped
    end
  end

  # Hard per-resource-per-tenant cap: at the cap, evict the least-recently
  # used entry (hits refresh `loaded_at`). If eviction is impossible, emit
  # `:full` and treat the new filter as not recorded.
  defp enforce_cap(resource, tenant) do
    cap = Info.ledger_max_entries(resource)

    if size(resource, tenant) >= cap do
      case resource |> entries(tenant) |> Enum.min_by(& &1.loaded_at, fn -> nil end) do
        nil ->
          Telemetry.ledger(:full, resource, tenant, %{ledger_size: size(resource, tenant)})
          :full

        oldest ->
          drop(resource, tenant, oldest.id)

          Telemetry.ledger(:evicted, resource, tenant, %{
            ledger_size: size(resource, tenant)
          })

          :ok
      end
    else
      :ok
    end
  end

  @doc "The fields a query needs: its select (or all attributes) plus the PK."
  @spec needed_fields(Query.t() | struct(), module()) :: MapSet.t(atom())
  def needed_fields(%Query{select: select}, resource) do
    fields =
      select ||
        Enum.map(Ash.Resource.Info.attributes(resource), & &1.name)

    MapSet.union(MapSet.new(fields), MapSet.new(Ash.Resource.Info.primary_key(resource)))
  end

  # Dedupe key: the canonicalised normalised form INCLUDING literal values —
  # unlike the telemetry fingerprint, which type-tags values away. Two
  # syntactically different but equivalently normalised filters share a key.
  defp dedupe_key(%{disjuncts: disjuncts}) do
    disjuncts
    |> Enum.map(fn disjunct ->
      disjunct
      |> Enum.map(fn {attr, interval} ->
        {attr, interval.kind, interval.lower, interval.upper, Enum.sort(interval.values)}
      end)
      |> Enum.sort()
    end)
    |> Enum.sort()
    |> :erlang.phash2()
  end

  defp touch(resource, tenant, entry) do
    insert(resource, tenant, %Entry{entry | loaded_at: System.monotonic_time()})
  end

  @doc "Current ledger size for a resource+tenant (for telemetry)."
  @spec size(module(), term()) :: non_neg_integer()
  def size(resource, tenant) do
    table = TableOwner.table_name(resource)
    key = tenant_key(tenant)
    :ets.select_count(table, [{{{key, :_}, :_}, [], [true]}])
  rescue
    ArgumentError -> 0
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
