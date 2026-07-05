defmodule AshMultiDatalayer.Orchestrator.ProvenCoverage do
  @moduledoc """
  The default orchestration strategy — today's behaviour, extracted verbatim
  from `AshMultiDatalayer.DataLayer` behind the
  `AshMultiDatalayer.Orchestrator` seam.

  Reads consult a per-resource coverage ledger: when a previously materialised
  filter provably subsumes the incoming query, the read is served by the earlier
  layer without touching later ones. Misses fall through to the source of truth
  and backfill. Writes go to the first layer in `write_order` (the source of
  truth) and the returned record is propagated to the remaining layers (see
  `AshMultiDatalayer.WriteDispatch`, this strategy's private write helper).

  ## Boundary funnels (forward-compat for stacked orchestrators)

  A future stacked variant needs to override "which layer is the source" without
  touching the read/write bodies. Every far-side access therefore routes through
  one internal function per direction:

  - `read_source_layer/1` — the read source of truth (`List.last(read_order)`);
    also this strategy's `authority/1` answer.
  - `write_authority_layer/1` — the authoritative write layer (`hd(write_order)`);
    also this strategy's `transaction_layer/1` answer, and the head
    `AshMultiDatalayer.WriteDispatch` writes to.

  Funneling only — no port abstraction is built here (that is the
  stacked-orchestrators RFC's territory, post-arc).
  """
  @behaviour AshMultiDatalayer.Orchestrator

  require Logger

  alias AshMultiDatalayer.Backfill
  alias AshMultiDatalayer.Capability
  alias AshMultiDatalayer.Coverage
  alias AshMultiDatalayer.DataLayer.Info
  alias AshMultiDatalayer.DataLayer.Query
  alias AshMultiDatalayer.Delegate
  alias AshMultiDatalayer.KillSwitch
  alias AshMultiDatalayer.Telemetry

  # Relationship-aggregate kinds we compute over a related resource — by a SQL
  # join or by a data layer's own in-memory fold (see `aggregate_read`).
  # `:custom` is excluded — it carries a module implementation we don't run.
  # (Duplicated in `AshMultiDatalayer.DataLayer`'s transitional `can?`; Phase 4a
  # consolidates capability logic here.)
  @foldable_aggregate_kinds [:count, :sum, :avg, :min, :max, :first, :list, :exists]

  # `AshPostgres.DataLayer.Info` is only present when a SQL layer is configured;
  # reference it softly, exactly as `AshMultiDatalayer.Migration` does.
  @compile {:no_warn_undefined, [AshPostgres.DataLayer.Info]}

  # --- boundary funnels --------------------------------------------------

  @doc false
  # The read source of truth — the last layer in `read_order`. Single funnel for
  # every far-side read access (`authority/1`, kill-switch/miss/merge/source
  # reads, run_aggregate_query).
  def read_source_layer(resource), do: List.last(Info.read_layer_modules(resource))

  @doc false
  # The authoritative write layer — the first in `write_order`. Single funnel for
  # every far-side write access (`transaction_layer/1`, WriteDispatch's head).
  def write_authority_layer(resource), do: hd(Info.write_layer_modules(resource))

  # --- structural answers -----------------------------------------------

  @doc false
  # ProvenCoverage participates in ash_sql aggregate-subquery passthrough: when
  # this resource is the *related* resource in a SQL parent's aggregate join, the
  # shell flips into the SQL source layer's `%Ecto.Query{}` so ash_sql can splice
  # a correlated in-DB join (see `AshMultiDatalayer.SqlPassthrough`). Independent
  # of this resource's own `sql_join_aggregates?` (that governs *its* aggregates,
  # not whether a parent may join over it), so unconditionally true — a strategy
  # with a complete authoritative local layer (LocalOutbox) returns false.
  def sql_passthrough?(_resource), do: true

  @impl AshMultiDatalayer.Orchestrator
  def authority(resource), do: read_source_layer(resource)

  @impl AshMultiDatalayer.Orchestrator
  def transaction_layer(resource), do: write_authority_layer(resource)

  # Phase 4a: the real per-strategy capability derivation (behaviour ADR's
  # feature classes). Concrete answers here; the shell's `:default` intersection
  # is only a fallback for a strategy that declines to answer.
  @impl AshMultiDatalayer.Orchestrator
  # bypass-guards — hardcoded false even where a layer says true, because the
  # feature would route work around orchestration inside a single layer (joined
  # rows escape the coverage proof; bulk/atomic/query-mutations bypass the write
  # dispatcher + invalidation). ash_sqlite advertises `update_query` — still false.
  def can?(_resource, {:join, _}), do: false
  def can?(_resource, {:lateral_join, _}), do: false
  def can?(_resource, :combine), do: false
  def can?(_resource, {:combine, _}), do: false
  def can?(_resource, :update_query), do: false
  def can?(_resource, :destroy_query), do: false
  def can?(_resource, {:atomic, _}), do: false
  def can?(_resource, :bulk_create), do: false
  def can?(_resource, :async_engine), do: false

  # aggregate filter/sort — clean loud refusal: filtering/sorting on a foldable
  # aggregate would crash with `KeyError __ash_bindings__` (implementation-review
  # M3). Refuse explicitly rather than surface the crash.
  def can?(_resource, :aggregate_filter), do: false
  def can?(_resource, :aggregate_sort), do: false

  # relationship aggregates — supported when a fold or join mechanism is enabled.
  def can?(resource, {:aggregate, kind}),
    do: aggregates_supported?(resource) and kind in @foldable_aggregate_kinds

  def can?(resource, {:aggregate_relationship, _}), do: aggregates_supported?(resource)

  # authority-only — features that only ever execute on the source of truth, so
  # the authority's answer is the honest one (not a pessimistic intersection that
  # a cache layer's inability would poison):
  #   * `:select` — the source builds the wire field list; a select-less cache
  #     just returns full rows for Ash to narrow.
  #   * `{:lock,_}` — a locked read routes to the source (run/2's lock branch); a
  #     source that supports locking should not lose it to the cache (N10).
  #   * `:transact` — matches `transaction/4`, which already delegates to the
  #     write authority alone.
  def can?(resource, :select), do: layer_can?(read_source_layer(resource), resource, :select)
  def can?(resource, {:lock, _} = f), do: layer_can?(read_source_layer(resource), resource, f)

  def can?(resource, :transact),
    do: layer_can?(write_authority_layer(resource), resource, :transact)

  # multitenancy — the all-layers intersection is load-bearing: a layer that
  # cannot isolate tenants would leak data.
  def can?(resource, :multitenancy),
    do: layers_can?(Info.layer_modules(resource), resource, :multitenancy)

  # write features — the write_order intersection (every layer receives the write).
  def can?(resource, feature) when feature in [:create, :update, :destroy, :upsert],
    do: layers_can?(Info.write_layer_modules(resource), resource, feature)

  # read-expressiveness features — the read_order intersection.
  def can?(resource, feature),
    do: layers_can?(Info.read_layer_modules(resource), resource, feature)

  # Relationship aggregates supported when at least one mechanism is enabled.
  defp aggregates_supported?(resource),
    do: Info.fold_aggregates?(resource) or Info.sql_join_aggregates?(resource)

  defp layer_can?(nil, _resource, _feature), do: false

  defp layer_can?(layer, resource, feature) do
    Code.ensure_loaded?(layer) and function_exported?(layer, :can?, 2) and
      layer.can?(resource, feature)
  end

  defp layers_can?([], _resource, _feature), do: false
  defp layers_can?(layers, resource, feature), do: Enum.all?(layers, & &1.can?(resource, feature))

  # ProvenCoverage keeps today's lazy start — table owners spawn on first use,
  # supervised by `AshMultiDatalayer.TableSupervisor` (already in the base
  # supervisor tree), so it needs no boot-time children (review D1/R6).
  @impl AshMultiDatalayer.Orchestrator
  def child_specs(_resources), do: []

  # --- inbound changes (notification bridge) ----------------------------

  # A change that bypassed this node's write path invalidates the row's coverage
  # so the next read fetches it fresh — `forget!/3` is exactly this (epoch bump +
  # ledger drops + physical eviction via `Invalidation.on_write/4`). Conservative
  # for updates (drop-then-refetch rather than in-place refresh), which is the
  # sound reaction under at-most-once notification delivery (RFC open question 7).
  @impl AshMultiDatalayer.Orchestrator
  def handle_external_change(resource, notification) do
    case notification.data do
      nil ->
        :ok

      record ->
        AshMultiDatalayer.forget!(resource, record, tenant: notification_tenant(notification))
    end

    :ok
  end

  # A notification gap (resubscribe/join-denied) carries no row-level info and
  # notifications are at-most-once — drop the whole ledger for resource+tenant.
  @impl AshMultiDatalayer.Orchestrator
  def handle_external_gap(resource, tenant) do
    AshMultiDatalayer.Coverage.Invalidation.drop_all(resource, tenant)
    :ok
  end

  defp notification_tenant(%{changeset: %{tenant: tenant}}), do: tenant
  defp notification_tenant(_), do: nil

  # --- writes ------------------------------------------------------------

  @impl AshMultiDatalayer.Orchestrator
  def create(resource, changeset), do: AshMultiDatalayer.WriteDispatch.create(resource, changeset)

  @impl AshMultiDatalayer.Orchestrator
  def update(resource, changeset), do: AshMultiDatalayer.WriteDispatch.update(resource, changeset)

  @impl AshMultiDatalayer.Orchestrator
  def destroy(resource, changeset),
    do: AshMultiDatalayer.WriteDispatch.destroy(resource, changeset)

  @impl AshMultiDatalayer.Orchestrator
  def upsert(resource, changeset, keys, identity),
    do: AshMultiDatalayer.WriteDispatch.upsert(resource, changeset, keys, identity)

  # --- reads -------------------------------------------------------------

  @impl AshMultiDatalayer.Orchestrator
  def read(%Query{} = query, resource) do
    read_layers = Info.read_layer_modules(resource)
    computed? = query.aggregates != [] or query.calculations != []

    cond do
      not KillSwitch.enabled?(resource) ->
        Delegate.run_on_layer(query, read_source_layer(resource))

      match?([_], read_layers) ->
        Delegate.run_on_layer(query, hd(read_layers))

      not is_nil(query.lock) ->
        source_read(
          query,
          resource,
          read_layers,
          :not_cacheable,
          Coverage.epoch(resource, query.tenant)
        )

      sort_references_uncomputable_calc?(query, resource, hd(read_layers)) ->
        # Sorting on a calc the cache layer can't evaluate (a source-only
        # `remote(...)`) must not be served from the cache — the coverage/merge
        # paths would hand the sort to the cache layer, which can't order by it.
        # `Coverage.epoch/2` calls `ensure_table` itself, so this branch (which
        # never passes through `covers?`) still warms from a cold start
        # (pass-6 F2).
        source_read(
          query,
          resource,
          read_layers,
          :calc_sort_source_only,
          Coverage.epoch(resource, query.tenant)
        )

      related_aggregates?(query, resource) ->
        # Relationship aggregates: a same-repo SQL one is joined in the database
        # by the source (bounded memory); the rest are folded by the cache layer.
        # Either way MDL delegates to a data layer's own read — see the ADR.
        aggregate_read(query, resource, read_layers)

      computed? and not AshMultiDatalayer.ValueMerge.mergeable?(resource) ->
        # Computed values are the source of truth's job; without a mergeable
        # primary key the whole query falls through.
        source_read(
          query,
          resource,
          read_layers,
          :not_cacheable,
          Coverage.epoch(resource, query.tenant)
        )

      computed? ->
        merged_read(query, resource, read_layers)

      true ->
        coverage_read(query, resource, read_layers)
    end
  end

  @impl AshMultiDatalayer.Orchestrator
  def run_aggregate_query(%Query{} = query, aggregates, resource) do
    layer = read_source_layer(resource)

    with {:ok, layer_query} <- Delegate.to_layer_query(query, layer) do
      Ash.DataLayer.run_aggregate_query(layer, layer_query, aggregates, resource)
    end
  end

  # --- relationship aggregate folding -----------------------------------

  # Relationship aggregates we compute ourselves by folding the related rows:
  # `related?`, a foldable kind, folding enabled, and not overridden to source.
  defp foldable_aggregates(%Query{aggregates: aggregates}, resource) do
    if Info.fold_aggregates?(resource) do
      overrides = Info.fold_aggregate_overrides(resource)

      Enum.filter(aggregates, fn
        %Ash.Query.Aggregate{related?: true, kind: kind, name: name} ->
          kind in @foldable_aggregate_kinds and name not in overrides

        _ ->
          false
      end)
    else
      []
    end
  end

  defp related_aggregates?(%Query{} = query, resource) do
    join_aggregates(query, resource) != [] or foldable_aggregates(query, resource) != []
  end

  # Compute relationship aggregates by delegating each to the data layer that
  # can produce it — never by folding them ourselves.
  #
  # When *every* aggregate is a same-repo SQL join, the SQL source returns the
  # rows, calcs and aggregates in a single read (the join is a DB operation, so
  # the parent rows come with it) — no redundant base read, no double source read
  # on a cache miss. This is the opt-out default path.
  #
  # Otherwise (a fold is involved, alone or mixed with a join) we first serve the
  # parent rows (+ calcs) through the normal read path — which also warms the
  # cache with them, since a fold is done by the cache layer and the SQL source
  # can't fold a non-SQL relationship. Then same-repo SQL aggregates go to the
  # SQL **source** (in-DB join) and the rest to the now-warm **cache** layer,
  # which folds them with its own implementation, loading each record's related
  # rows through their data layer (this module → 0 source reads when covered).
  # Each delegated read computes through the layer's standard `run_query`; the
  # values are stitched back onto the rows by primary key.
  defp aggregate_read(%Query{} = query, resource, read_layers) do
    started = System.monotonic_time()
    join = join_aggregates(query, resource)
    fold = foldable_aggregates(%{query | aggregates: query.aggregates -- join}, resource)

    if fold == [] and query.aggregates -- join == [] do
      with {:ok, rows} <- Delegate.run_on_layer(query, read_source_layer(resource)) do
        emit_read(:aggregate_read, query, resource, started, %{joined: length(join), folded: 0})
        {:ok, rows}
      end
    else
      base_query = %{query | aggregates: query.aggregates -- (join ++ fold)}

      with {:ok, rows} <- read(base_query, resource),
           {:ok, rows} <-
             add_aggregates_via_layer(rows, join, query, resource, read_source_layer(resource)),
           {:ok, rows} <- add_aggregates_via_layer(rows, fold, query, resource, hd(read_layers)) do
        emit_read(:aggregate_read, query, resource, started, %{
          joined: length(join),
          folded: length(fold)
        })

        {:ok, rows}
      end
    end
  end

  # Relationship aggregates the SQL source computes as an in-database join: a
  # foldable kind over a related resource whose own source of truth is a SQL
  # layer in the same repo as ours, with the join enabled and not overridden to
  # fold. See `AshMultiDatalayer.SqlPassthrough` and the aggregates ADR.
  defp join_aggregates(%Query{aggregates: aggregates}, resource) do
    if Info.sql_join_aggregates?(resource) do
      overrides = Info.sql_join_aggregate_overrides(resource)
      Enum.filter(aggregates, &join_eligible?(resource, overrides, &1))
    else
      []
    end
  end

  defp join_eligible?(resource, overrides, %Ash.Query.Aggregate{
         related?: true,
         kind: kind,
         name: name,
         relationship_path: path
       })
       when kind in @foldable_aggregate_kinds do
    name not in overrides and
      same_repo_sql?(resource, Ash.Resource.Info.related(resource, path))
  end

  defp join_eligible?(_resource, _overrides, _aggregate), do: false

  # Both resources' sources of truth are SQL layers in the same repo — the only
  # case a correlated in-DB join can span. Detected via the postgres section
  # each carries (so a counting/wrapping SQL layer, which keys off the section
  # rather than the layer module, is handled too).
  defp same_repo_sql?(resource, related) do
    repo = sql_repo(resource)
    not is_nil(repo) and repo == sql_repo(related)
  end

  defp sql_repo(resource) do
    AshPostgres.DataLayer.Info.repo(resource, :read)
  rescue
    _ -> nil
  end

  # Compute the aggregates in `aggs` over the already-fetched parent `rows` by
  # delegating one query — same filter/sort/limit, aggregates only, calcs
  # stripped — to `layer` through the standard read callbacks (`add_aggregates` →
  # `return_query` → `run_query`). The layer's own code does the work (SQL joins,
  # ETS folds); we stitch the values back onto `rows` by primary key.
  defp add_aggregates_via_layer(rows, [], _query, _resource, _layer), do: {:ok, rows}

  defp add_aggregates_via_layer(rows, aggs, query, resource, layer) do
    agg_query = %{query | aggregates: aggs, calculations: []}

    with {:ok, agg_rows} <- Delegate.run_on_layer(agg_query, layer) do
      [pk] = Ash.Resource.Info.primary_key(resource)
      by_pk = Map.new(agg_rows, &{Map.fetch!(&1, pk), &1})

      merged =
        Enum.map(rows, fn row ->
          copy_aggregate_values(row, Map.get(by_pk, Map.fetch!(row, pk)), aggs)
        end)

      {:ok, merged}
    end
  end

  defp copy_aggregate_values(row, nil, _aggs), do: row

  defp copy_aggregate_values(row, agg_row, folded) do
    Enum.reduce(folded, row, fn %Ash.Query.Aggregate{load: load, name: name}, row ->
      if load do
        Map.put(row, load, Map.get(agg_row, load))
      else
        value = agg_row.aggregates |> Kernel.||(%{}) |> Map.get(name)
        Map.update!(row, :aggregates, &Map.put(&1, name, value))
      end
    end)
  end

  # An aggregate handed to the source of truth (the per-aggregate
  # `fold_aggregate_overrides` escape hatch, or folding turned off) that the
  # source cannot compute over an MDL-wrapped related resource comes back as
  # %Ash.NotLoaded{}. Refuse it loudly rather than surface a silent nil — the
  # one failure shape this library rejects. Fold it instead (the default).
  defp ensure_source_aggregates_resolved!(%Query{aggregates: []}, _records), do: :ok

  defp ensure_source_aggregates_resolved!(%Query{aggregates: aggregates}, records) do
    unresolved =
      for aggregate <- aggregates,
          record <- records,
          match?(%Ash.NotLoaded{}, aggregate_result(record, aggregate)),
          uniq: true,
          do: aggregate.name

    if unresolved != [] do
      raise ArgumentError,
            "the source of truth could not compute aggregate(s) #{inspect(unresolved)} " <>
              "(a relationship aggregate over an MDL-wrapped resource cannot be built as a " <>
              "source-side join). Remove them from `fold_aggregate_overrides` / keep " <>
              "`fold_aggregates?` on so this layer folds them from the related rows."
    end

    :ok
  end

  defp aggregate_result(record, %Ash.Query.Aggregate{load: load}) when not is_nil(load),
    do: Map.get(record, load)

  defp aggregate_result(record, %Ash.Query.Aggregate{name: name}),
    do: record.aggregates |> Kernel.||(%{}) |> Map.get(name)

  # A calc referenced in the FILTER routes to the source via the normaliser
  # (a calc ref is opaque — no false coverage hit). A calc referenced in the
  # SORT needs a separate guard: coverage/merge would replay the sort onto the
  # cache layer, which can't order by a calc it can't compute.
  defp sort_references_uncomputable_calc?(%Query{sort: sort}, resource, cache_layer) do
    Enum.any?(sort, fn
      {%Ash.Query.Calculation{} = calc, _direction} ->
        not calc_evaluable_by?(cache_layer, resource, calc)

      _ ->
        false
    end)
  end

  defp calc_evaluable_by?(layer, resource, %Ash.Query.Calculation{opts: opts})
       when is_list(opts) do
    case opts[:expr] do
      nil -> false
      expression -> Capability.layer_can_evaluate?(layer, resource, expression)
    end
  end

  defp calc_evaluable_by?(_layer, _resource, _calc), do: false

  defp coverage_read(%Query{} = query, resource, read_layers) do
    started = System.monotonic_time()

    case Coverage.covers?(resource, query.tenant, query) do
      {:ok, _entry} ->
        with {:ok, records} <- Delegate.run_on_layer(query, hd(read_layers)) do
          emit_read(:hit, query, resource, started, %{})
          AshMultiDatalayer.Divergence.maybe_sample(query, resource, records)
          {:ok, records}
        end

      {:miss, reason} ->
        # Snapshotted BEFORE `remainder_plan`'s `coverage_split` (and
        # therefore before the cache-side region fetch too, on the
        # remainder branch) — a snapshot taken only before the source fetch
        # would be blind to a writer landing between the two halves
        # (review-1 C-P1 / review-2 F5).
        epoch0 = Coverage.epoch(resource, query.tenant)

        case remainder_plan(query, resource) do
          {:ok, coverage, complement} ->
            remainder_read(query, resource, read_layers, coverage, complement, epoch0)

          :none ->
            source_read(query, resource, read_layers, reason, epoch0)
        end
    end
  end

  # A remainder read serves the covered part of Q (`Q ∧ C`) from the cache and
  # fetches only the uncovered remainder (`Q ∧ ¬C`) from the source, merging by
  # primary key. Applicable to a plain (recordable, unsorted, single-PK) read
  # that overlaps existing coverage — sort/limit/offset can't be split across
  # two reads soundly, so those fall through whole.
  defp remainder_plan(%Query{} = query, resource) do
    if remainder_applicable?(query, resource) do
      needed = Coverage.needed_fields(query, resource)

      case Coverage.coverage_split(resource, query.tenant, needed) do
        :none -> :none
        {coverage, complement} -> {:ok, coverage, complement}
      end
    else
      :none
    end
  end

  # Opaque probes never split (review-2 F3): a filter the normaliser can't
  # see through (a calc/aggregate ref, an unsupported predicate) must fall
  # through to the source whole, exactly like the full-hit path already
  # does — its demands are invisible to every field set this planner builds,
  # and it can never record coverage either.
  defp remainder_applicable?(%Query{} = query, resource) do
    {gate, _probe} = Coverage.recordable_gate(query, resource)

    gate and
      query.sort in [nil, []] and
      match?([_], Ash.Resource.Info.primary_key(resource))
  end

  defp remainder_read(%Query{} = query, resource, read_layers, coverage, complement, epoch0) do
    started = System.monotonic_time()
    cache_layer = hd(read_layers)
    source_layer = read_source_layer(resource)
    earlier_layers = Enum.drop(read_layers, -1)
    source_fetch_query = widen_select_for_backfill(query, resource, earlier_layers)

    with {:ok, cache_rows} <- run_region(query, cache_layer, coverage),
         {:ok, source_rows} <- run_region(source_fetch_query, source_layer, complement) do
      merged = pk_merge(source_rows, cache_rows, resource)

      emit_read(:partial, query, resource, started, %{
        cached: length(cache_rows),
        fetched: length(source_rows)
      })

      # Backfill/reconcile/record consume the SOURCE-HALF rows only, never
      # `merged` (review-2 F4): cache-half rows are already physically
      # present (recording Q needs nothing re-upserted for them), and
      # re-upserting them risks clobbering good values with
      # `%Ash.NotLoaded{}` sentinels behind a select-honouring cache layer,
      # or laundering a stale/ghost cache-half row into "freshly backfilled"
      # state. The caller still gets `merged`.
      maybe_backfill(query, resource, read_layers, source_rows, epoch0, complement: complement)
      AshMultiDatalayer.Divergence.maybe_sample(query, resource, merged)
      {:ok, merged}
    end
  end

  # Runs Q restricted to a coverage region on a layer. `:empty` yields no rows
  # without touching the layer; `:universe` runs Q unrestricted.
  defp run_region(_query, _layer, :empty), do: {:ok, []}

  defp run_region(%Query{} = query, layer, :universe),
    do: Delegate.run_on_layer(query, layer)

  defp run_region(%Query{} = query, layer, {:ok, region}) do
    Delegate.run_on_layer(%{query | filter: and_filter(query.filter, region)}, layer)
  end

  defp and_filter(nil, region), do: region
  defp and_filter(base, region), do: Ash.Filter.add_to_filter!(base, region)

  # PK-union, preferring the freshly-fetched source rows over cached ones.
  defp pk_merge(preferred, others, resource) do
    [pk] = Ash.Resource.Info.primary_key(resource)
    seen = MapSet.new(preferred, &Map.fetch!(&1, pk))
    preferred ++ Enum.reject(others, &MapSet.member?(seen, Map.fetch!(&1, pk)))
  end

  # Computed-value merge read: rows from covered cache, calcs computed on the
  # layer that can (local evaluation), and one narrow value query for the
  # source-only calculations/aggregates, merged by primary key. See the
  # 20260703-computed-value-merge-reads ADR.
  defp merged_read(%Query{} = query, resource, read_layers) do
    started = System.monotonic_time()
    cache_layer = hd(read_layers)

    {local_calcs, source_calcs} =
      AshMultiDatalayer.ValueMerge.local_and_source_calculations(query, resource, cache_layer)

    # The cache layer serves the rows AND computes the calcs it can evaluate;
    # only the source-only calcs (and aggregates) round-trip to the source.
    cache_query = %{query | calculations: local_calcs, aggregates: []}
    source_query = %{query | calculations: source_calcs}

    with {:ok, _entry} <- Coverage.covers?(resource, query.tenant, cache_query),
         {:ok, rows} <- Delegate.run_on_layer(cache_query, cache_layer) do
      case AshMultiDatalayer.ValueMerge.merge(
             source_query,
             rows,
             resource,
             read_source_layer(resource)
           ) do
        {:ok, merged} ->
          ensure_source_aggregates_resolved!(source_query, merged)

          emit_read(:hit, query, resource, started, %{computed_values: computed_tag(source_query)})

          AshMultiDatalayer.Divergence.maybe_sample(query, resource, merged)
          {:ok, merged}

        :stale_cache ->
          # A cached row has no source counterpart (out-of-band delete):
          # abandon the merge, serve everything fresh.
          source_read(
            query,
            resource,
            read_layers,
            :stale_cache,
            Coverage.epoch(resource, query.tenant)
          )

        {:error, error} ->
          {:error, error}
      end
    else
      {:miss, reason} ->
        source_read(query, resource, read_layers, reason, Coverage.epoch(resource, query.tenant))

      {:error, error} ->
        {:error, error}
    end
  end

  # `:local` when every value was computed from the cache (no source read),
  # `:merged` when the source of truth supplied some calcs/aggregates.
  defp computed_tag(%Query{calculations: [], aggregates: []}), do: :local
  defp computed_tag(%Query{}), do: :merged

  defp source_read(%Query{} = query, resource, read_layers, miss_reason, epoch0) do
    started = System.monotonic_time()
    earlier_layers = Enum.drop(read_layers, -1)
    fetch_query = widen_select_for_backfill(query, resource, earlier_layers)

    with {:ok, records} <- Delegate.run_on_layer(fetch_query, read_source_layer(resource)) do
      emit_read(:miss, query, resource, started, %{reason: miss_reason})
      maybe_backfill(query, resource, read_layers, records, epoch0)
      {:ok, records}
    end
  end

  # A narrow-select source read returns rows WITHOUT the filter/sort/calc
  # fields `needed_fields` demands — backfilling those into the cache would
  # copy `nil`s (or `%Ash.NotLoaded{}`s) instead of real values. Widen the
  # SOURCE query's select to the superset `needed_fields` computes before
  # fetching; the caller-visible result is unaffected — Ash's own action
  # pipeline narrows the final struct back to the query's actual select
  # (same reason a select-blind layer returning full rows is already fine).
  defp widen_select_for_backfill(%Query{select: nil} = query, _resource, _earlier_layers),
    do: query

  defp widen_select_for_backfill(%Query{} = query, resource, earlier_layers) do
    if earlier_layers != [] and Coverage.recordable?(query) do
      %{query | select: Enum.to_list(Coverage.needed_fields(query, resource))}
    else
      query
    end
  end

  # `source_rows` are the previously-uncovered rows just fetched from the
  # source of truth (the whole result on the full-miss path; the source
  # HALF only on the remainder path — never `merged`, see `remainder_read`).
  # `epoch0` is the invalidation-epoch snapshot taken at the top of the read
  # (before `source_rows` was even fetched), guarding both the physical
  # backfill and the coverage record against a write that raced this read.
  # `opts[:complement]` is the remainder planner's `¬C` region (`nil` on the
  # full-miss path, where reconcile scans the whole of Q instead).
  defp maybe_backfill(%Query{} = query, resource, read_layers, source_rows, epoch0, opts \\ []) do
    earlier_layers = Enum.drop(read_layers, -1)
    {gate, probe} = Coverage.recordable_gate(query, resource)

    cond do
      not (gate and earlier_layers != []) ->
        :ok

      Coverage.epoch_moved?(resource, query.tenant, epoch0) ->
        # A write raced this read before the backfill even started: the
        # fetched rows are still returned to the caller (the read result
        # itself is not stale), but caching them would be unsafe.
        Telemetry.read(:backfill_aborted, resource, query, %{}, %{reason: :epoch_moved})
        :ok

      true ->
        started = System.monotonic_time()

        backfill_opts = [
          tenant: query.tenant,
          domain: query.domain,
          fields: Enum.to_list(Coverage.needed_fields(query, resource))
        ]

        case Backfill.upsert_records(earlier_layers, resource, source_rows, backfill_opts) do
          :ok ->
            reconcile(query, resource, earlier_layers, source_rows, opts[:complement])

            case Coverage.record(resource, query.tenant, query, epoch0, probe) do
              :ok ->
                emit_read(:backfill, query, resource, started, %{records: length(source_rows)})

              :skipped ->
                :ok

              :epoch_moved ->
                Telemetry.read(:backfill_aborted, resource, query, %{}, %{
                  reason: :epoch_moved_at_record
                })
            end

          {:error, layer, reason} ->
            # No coverage is recorded for a partial backfill — the next read
            # falls through again. A cache-population failure is never an
            # operation failure.
            Logger.warning(
              "ash_multi_datalayer backfill into #{inspect(layer)} failed for " <>
                "#{inspect(resource)}: #{inspect(reason)}"
            )
        end
    end

    :ok
  end

  # Reconcile-on-record (C4, defense in depth): deletes cached rows matching
  # the region just (re-)recorded whose primary key is NOT in the
  # source-fetched set — the residue of a failed physical eviction
  # (`Coverage.Invalidation`'s evict-on-write), and any stale/ghost row
  # under a region being freshly re-recorded. Scan region and fetch region
  # are the SAME object as the just-completed source fetch (pass-8 F1): the
  # entry set is not stable across this window (concurrent records, LRU
  # evictions, other readers' verify-drops), so recomputing the region here
  # instead of reusing `complement` could scan a region wider than what was
  # actually fetched and delete fresh, legitimate rows outside it.
  #
  # On the full-miss path (`complement: nil`), the scan is the whole of Q.
  # On the remainder path, only `Q ∧ ¬C` is scanned — the covered half needs
  # no reconcile (every surviving entry's region provably excludes a stale
  # physical row: any row whose before-image matched it would have dropped
  # it via `Invalidation.on_write`) and must not be reconciled against the
  # source-fetched set, since covered-half rows are legitimately absent
  # from a `¬C`-only fetch.
  defp reconcile(_query, _resource, _earlier_layers, _source_rows, :empty), do: :ok

  defp reconcile(%Query{} = query, resource, earlier_layers, source_rows, complement) do
    [pk] = Ash.Resource.Info.primary_key(resource)
    fetched_pks = MapSet.new(source_rows, &Map.fetch!(&1, pk))

    reconcile_query = %Query{
      resource: resource,
      domain: query.domain,
      tenant: query.tenant,
      context: query.context,
      filter: reconcile_filter(query, complement),
      select: Ash.Resource.Info.primary_key(resource),
      sort: [],
      calculations: [],
      aggregates: [],
      distinct: [],
      distinct_sort: nil,
      limit: nil,
      offset: 0,
      lock: nil
    }

    Enum.each(
      earlier_layers,
      &reconcile_layer(&1, reconcile_query, resource, query, pk, fetched_pks)
    )
  end

  defp reconcile_filter(%Query{filter: filter}, nil), do: filter
  defp reconcile_filter(%Query{filter: filter}, :universe), do: filter
  defp reconcile_filter(%Query{filter: filter}, {:ok, region}), do: and_filter(filter, region)

  defp reconcile_layer(layer, reconcile_query, resource, original_query, pk, fetched_pks) do
    case Delegate.run_on_layer(reconcile_query, layer) do
      {:ok, cached_rows} ->
        cached_rows
        |> Enum.reject(&MapSet.member?(fetched_pks, Map.fetch!(&1, pk)))
        |> Enum.each(&evict_ghost(layer, resource, &1, original_query))

      {:error, reason} ->
        # Neither failing the read (it already succeeded) nor skipping the
        # record (the backfill was fine) is correct — proceed to `record`,
        # which has its own epoch guard; any ghost a skipped reconcile
        # leaves is unservable until the next re-covering read reconciles
        # again (defense in depth degrades gracefully by construction).
        Logger.warning(
          "ash_multi_datalayer reconcile scan on #{inspect(layer)} failed for " <>
            "#{inspect(resource)}: #{inspect(reason)}"
        )

        Telemetry.read(:backfill_aborted, resource, original_query, %{}, %{
          reason: :reconcile_scan_failed
        })
    end
  end

  defp evict_ghost(layer, resource, ghost_row, query) do
    case Backfill.destroy_record(layer, resource, ghost_row,
           tenant: query.tenant,
           domain: query.domain
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "ash_multi_datalayer reconcile eviction on #{inspect(layer)} failed for " <>
            "#{inspect(resource)}: #{inspect(reason)}"
        )

        Telemetry.ledger(:evict_failed, resource, query.tenant, %{}, %{
          layer: layer,
          reason: reason
        })
    end
  end

  defp emit_read(kind, query, resource, started, extra) do
    Telemetry.read(
      kind,
      resource,
      query,
      %{
        duration_us: Telemetry.duration_us(started),
        ledger_size: Coverage.size(resource, query.tenant)
      },
      extra
    )
  end
end
