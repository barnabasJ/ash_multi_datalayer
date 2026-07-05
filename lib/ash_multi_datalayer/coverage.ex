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

  alias AshMultiDatalayer.Coverage.{Complement, Entry, Implication, Normaliser, TableOwner}
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
  @spec insert(module(), term(), %{:id => term(), optional(any()) => any()}) :: :ok
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
  Whether a query's row coverage may be recorded (and its rows backfilled).

  Truncated result sets can't prove complete coverage of a filter: queries
  with `limit`, a non-zero `offset`, `distinct`, `distinct_sort`, or a
  `lock` are never recorded — recording one would later serve incomplete
  results as a cache hit. Sort does not affect set membership and is fine.
  Calculations/aggregates don't affect recordability: the *rows* fetched
  alongside them are complete for the filter (the computed values themselves
  are never recorded — see the computed-value merge-reads ADR).
  """
  @spec recordable?(Query.t() | struct()) :: boolean()
  def recordable?(%Query{} = query) do
    is_nil(query.limit) and
      query.offset in [nil, 0] and
      query.distinct in [nil, []] and
      query.distinct_sort in [nil, []] and
      is_nil(query.lock)
  end

  @doc """
  The shared gate for anything that would replay the query against a cache
  layer for bookkeeping purposes (the remainder planner's split, and the
  read path's reconcile-on-record step): `recordable?(query) and not
  normalised.opaque?`, normalising the filter once so callers that also need
  the normalised probe (reconcile, `record`) don't re-normalise.

  An opaque probe (a calc/aggregate ref, or any shape outside the supported
  predicate set) must never split or be reconciled against the cache layer —
  it cannot prove what a cache-side replay would return, so both the
  remainder planner and reconcile treat it exactly like a full-hit miss:
  fall through whole to the source (review-2 F3).
  """
  @spec recordable_gate(Query.t() | struct(), module()) :: {boolean(), Normaliser.Normalised.t()}
  def recordable_gate(%Query{} = query, resource) do
    normalised = Normaliser.normalise(query.filter, resource)
    {recordable?(query) and not normalised.opaque?, normalised}
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

  @doc """
  The current coverage region for a resource+tenant, as
  `{coverage_filter, complement_filter}` (see
  `AshMultiDatalayer.Coverage.Complement`), or `:none` when nothing is cached.

  `C` is the union of every current ledger entry's normalised filter **whose
  `loaded_fields` are a superset of `needed`** — a per-entry field gate,
  exactly like a full hit (plan rule 4 of the partial-serving-remainder-reads
  plan). A legitimately-narrow entry must not contribute region to a wider
  query's split even after `needed_fields` itself is widened (C1): entries
  failing the gate contribute nothing to `C` and their rows are fetched from
  the source via `¬C` instead — correct, merely less cached.

  Remainder reads serve `Q ∧ C` from the cache and fetch only `Q ∧ ¬C` from
  the source.
  """
  @spec coverage_split(module(), term(), MapSet.t(atom())) ::
          {Complement.region(), Complement.region()} | :none
  def coverage_split(resource, tenant, needed) do
    disjuncts =
      resource
      |> entries(tenant)
      |> Enum.filter(&MapSet.subset?(needed, &1.loaded_fields))
      |> Enum.flat_map(& &1.normalised.disjuncts)
      |> Enum.uniq()

    case disjuncts do
      [] ->
        :none

      _ ->
        {Complement.coverage_filter(disjuncts, resource),
         Complement.complement_filter(disjuncts, resource)}
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

  On a fingerprint match against an existing entry, the query's
  `needed_fields` are UNIONED into that entry's `loaded_fields` instead of
  being a no-op (review-2 F2): sound because the backfill that just ran
  wrote those fields into the physical rows, and it is what stops a
  narrow-then-wide same-filter workload from being a permanent miss loop
  (the wide read would otherwise re-miss on `:fields_insufficient` forever,
  since the entry keeps claiming the narrow set). Two readers concurrently
  widening the same entry with disjoint field sets is a last-writer-wins
  union on the metadata only — the physical rows are unaffected
  (`force_change_attributes` never strips fields) — so the only consequence
  is a transient unnecessary miss that a later read re-widens, never
  staleness; not worth a CAS loop (pass-3 S1).

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
      needed = needed_fields(query, resource)

      case Enum.find(entries(resource, tenant), &(&1.fingerprint == fingerprint)) do
        %Entry{} = existing ->
          widen_loaded_fields(resource, tenant, existing, needed)
          :ok

        nil ->
          if enforce_cap(resource, tenant) == :full do
            :skipped
          else
            entry = %Entry{
              id: make_ref(),
              tenant: tenant_key(tenant),
              filter: query.filter,
              normalised: normalised,
              fingerprint: fingerprint,
              loaded_fields: needed,
              loaded_at: System.monotonic_time()
            }

            insert(resource, tenant, entry)
          end
      end
    else
      _ -> :skipped
    end
  end

  defp widen_loaded_fields(resource, tenant, %Entry{loaded_fields: loaded} = existing, needed) do
    if MapSet.subset?(needed, loaded) do
      :ok
    else
      table = TableOwner.table_name(resource)
      widened = MapSet.union(loaded, needed)

      :ets.update_element(
        table,
        {tenant_key(tenant), existing.id},
        {2, %Entry{existing | loaded_fields: widened}}
      )

      :ok
    end
  rescue
    ArgumentError -> :ok
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

  @doc """
  The fields a query touches: everything a cache layer must physically hold
  to both backfill and re-evaluate the query — not just its select.

  The union of:

    * `query.select` (or all attributes when `nil`), plus the primary key;
    * attribute refs from `query.filter`;
    * `query.sort` fields (a calc-sort's expression refs, for the atoms
      directly);
    * `query.distinct` fields and `query.distinct_sort`'s refs;
    * attribute refs from every `query.calculations` expression — this is
      what makes a merged-read's cache-side probe (which carries the
      locally-evaluated calcs) demand the fields those calcs read.

  Only refs with an empty `relationship_path` that resolve to a real
  resource attribute count — a calc/aggregate ref or a related-path ref is
  not a field of this resource's own rows (and filters containing one are
  opaque to the normaliser regardless).
  """
  @spec needed_fields(Query.t() | struct(), module()) :: MapSet.t(atom())
  def needed_fields(%Query{} = query, resource) do
    select_fields =
      query.select ||
        Enum.map(Ash.Resource.Info.attributes(resource), & &1.name)

    MapSet.new(select_fields)
    |> MapSet.union(MapSet.new(Ash.Resource.Info.primary_key(resource)))
    |> MapSet.union(expression_attribute_refs(query.filter, resource))
    |> MapSet.union(sort_fields(query.sort, resource))
    |> MapSet.union(sort_fields(query.distinct_sort, resource))
    |> MapSet.union(MapSet.new(query.distinct || []))
    |> MapSet.union(calculation_fields(query.calculations, resource))
  end

  # `query.sort`/`query.distinct_sort` entries are `{field, direction}` with
  # `field` either a plain attribute atom, or `%Ash.Query.Calculation{}` for
  # a calc-sort (only locally-evaluable calc sorts ever reach a cache layer —
  # `sort_references_uncomputable_calc?` already guards the rest). A
  # calc-sort's expression lives at `calc.opts[:expr]`, NOT as a second tuple
  # element (that slot is the sort direction) — reading the wrong one would
  # silently return no fields for a calc sort (the M5-class hole).
  defp sort_fields(nil, _resource), do: MapSet.new()

  defp sort_fields(sort, resource) do
    Enum.reduce(sort, MapSet.new(), fn
      {%Ash.Query.Calculation{opts: opts}, _direction}, acc when is_list(opts) ->
        MapSet.union(acc, expression_attribute_refs(opts[:expr], resource))

      {field, _direction}, acc when is_atom(field) ->
        MapSet.put(acc, field)

      field, acc when is_atom(field) ->
        MapSet.put(acc, field)

      _other, acc ->
        acc
    end)
  end

  # `query.calculations` entries are `{calculation, expression}` tuples —
  # here `expression` (the second element) is already the hydrated
  # expression tree, unlike a calc-sort's `opts[:expr]`.
  defp calculation_fields(calculations, resource) do
    Enum.reduce(calculations, MapSet.new(), fn {_calculation, expression}, acc ->
      MapSet.union(acc, expression_attribute_refs(expression, resource))
    end)
  end

  defp expression_attribute_refs(nil, _resource), do: MapSet.new()

  defp expression_attribute_refs(expression, resource) do
    expression
    |> Ash.Filter.list_refs()
    |> Enum.filter(&(&1.relationship_path == []))
    |> Enum.flat_map(fn ref ->
      case resource_attribute_name(ref.attribute, resource) do
        {:ok, name} -> [name]
        :error -> []
      end
    end)
    |> MapSet.new()
  end

  # Mirrors `Normaliser.ref_attribute/2`'s attribute-vs-calc/aggregate
  # distinction: a calc/aggregate struct also carries `:name`/`:type` keys,
  # so it must be excluded BEFORE the generic `%{name: name}` match — treating
  # one as a plain attribute would demand a field that doesn't exist on the
  # resource's rows.
  defp resource_attribute_name(%struct{}, _resource)
       when struct in [
              Ash.Query.Calculation,
              Ash.Resource.Calculation,
              Ash.Query.Aggregate,
              Ash.Resource.Aggregate
            ],
       do: :error

  defp resource_attribute_name(%{name: name}, _resource), do: {:ok, name}

  defp resource_attribute_name(name, resource) when is_atom(name) do
    case Ash.Resource.Info.attribute(resource, name) do
      %{name: name} -> {:ok, name}
      _ -> :error
    end
  end

  defp resource_attribute_name(_other, _resource), do: :error

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
