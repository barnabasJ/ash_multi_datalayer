defmodule AshMultiDatalayer.DataLayer do
  @moduledoc """
  An `Ash.DataLayer` that composes multiple underlying data layers behind a
  single resource, in user-declared order.

  Resources declare their layers and routing in a `multi_data_layer` DSL
  section:

      use Ash.Resource,
        domain: MyApp.Domain,
        data_layer: AshMultiDatalayer.DataLayer

      multi_data_layer do
        layer :l1, Ash.DataLayer.Ets
        layer :l2, AshPostgres.DataLayer

        read_order [:l1, :l2]
        write_order [:l2, :l1]
      end

  Reads consult a per-resource coverage ledger: when a previously materialised
  filter provably subsumes the incoming query, the read is served by the
  earlier layer without touching later ones. Misses fall through and backfill.
  Writes go to the first layer in `write_order` (the source of truth) and the
  returned record is propagated to the remaining layers.
  """
  @behaviour Ash.DataLayer

  @layer %Spark.Dsl.Entity{
    name: :layer,
    describe: """
    Declares a named underlying data layer. The name is yours to pick (e.g.
    `:l1`/`:l2`, `:cache`/`:remote`) and is referenced by `read_order` and
    `write_order`.
    """,
    examples: [
      "layer :l1, Ash.DataLayer.Ets",
      "layer :l2, AshPostgres.DataLayer"
    ],
    target: AshMultiDatalayer.Layer,
    args: [:name, :module],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The name used to reference this layer in `read_order`/`write_order`."
      ],
      module: [
        type: :atom,
        required: true,
        doc: "The `Ash.DataLayer` module backing this layer."
      ]
    ]
  }

  @multi_data_layer %Spark.Dsl.Section{
    name: :multi_data_layer,
    describe: """
    Configuration for routing this resource's reads and writes across multiple
    underlying data layers.
    """,
    examples: [
      """
      multi_data_layer do
        layer :l1, Ash.DataLayer.Ets
        layer :l2, AshPostgres.DataLayer

        read_order [:l1, :l2]
        write_order [:l2, :l1]
      end
      """
    ],
    entities: [@layer],
    schema: [
      read_order: [
        type: {:list, :atom},
        required: true,
        doc: """
        Layer names consulted for reads, in order. With more than one layer,
        reads are served by an earlier layer whenever the coverage ledger
        proves it holds the query's full result; otherwise they fall through
        to the next layer and backfill.
        """
      ],
      write_order: [
        type: {:list, :atom},
        required: true,
        doc: """
        Layer names written on create/update/destroy, in order. The first
        layer is authoritative (fail-fast); the record it returns is
        propagated to the remaining layers.
        """
      ],
      ledger_max_entries: [
        type: :pos_integer,
        default: 10_000,
        doc: """
        Hard cap on coverage-ledger entries per resource and tenant. At the
        cap, the least-recently-used entry is evicted.
        """
      ],
      divergence_sampler: [
        type: :float,
        default: 0.0,
        doc: """
        Fraction (0.0..1.0) of coverage-hit reads that are additionally
        re-run against the last read layer to detect cache divergence,
        emitting telemetry on mismatch. Off by default — sampling adds one
        extra lower-layer query per sampled hit. Useful in dev, or in
        production as an opt-in tracing aid.
        """
      ],
      local_evaluation?: [
        type: :boolean,
        default: true,
        doc: """
        Whether a loaded calculation whose expression an earlier read layer
        can evaluate is computed by that layer from the covered rows, instead
        of round-tripping to the source of truth for its value. On by default:
        it removes a source read for every reproducible calculation (a
        mirrored expression like `overdue?`). Calculations the cache layer
        cannot evaluate (an `ash_remote` `remote(...)`) are always fetched
        from the source regardless.

        Correctness relies on the layers agreeing on the expression's value;
        keeping them consistent (collation, numeric/date semantics) is the
        operator's responsibility (see the layer-consistency contract). Turn
        this off to force every calculation to the source of truth.
        """
      ],
      local_evaluation_overrides: [
        type: {:list, :atom},
        default: [],
        doc: """
        Calculation names always computed by the source of truth even when a
        cache layer could evaluate them — the per-calc escape hatch for
        `local_evaluation?` (e.g. a clock-dependent calc where a caller wants
        the source's exact evaluation instant).
        """
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@multi_data_layer],
    verifiers: [
      AshMultiDatalayer.Verifiers.ValidateLayers,
      AshMultiDatalayer.Verifiers.ValidateMultitenancy,
      AshMultiDatalayer.Verifiers.RejectFieldPolicies,
      AshMultiDatalayer.Verifiers.RejectMultiNode,
      AshMultiDatalayer.Verifiers.ValidateSolverSupportedPredicates
    ]

  defmodule Query do
    @moduledoc false
    # Accumulates everything Ash's canonical query build hands a data layer,
    # so it can be replayed verbatim onto an underlying layer (see
    # AshMultiDatalayer.Delegate).
    defstruct [
      :resource,
      :domain,
      :filter,
      :limit,
      :tenant,
      :select,
      :lock,
      sort: [],
      distinct: [],
      distinct_sort: nil,
      context: %{},
      calculations: [],
      aggregates: [],
      offset: 0
    ]

    @type t :: %__MODULE__{}
  end

  require Logger

  alias AshMultiDatalayer.Backfill
  alias AshMultiDatalayer.Capability
  alias AshMultiDatalayer.Coverage
  alias AshMultiDatalayer.DataLayer.Info
  alias AshMultiDatalayer.Delegate
  alias AshMultiDatalayer.KillSwitch
  alias AshMultiDatalayer.Telemetry

  # --- capabilities --------------------------------------------------------
  #
  # Read features answer from the intersection of read_order layers, write
  # features from write_order layers, multitenancy from ALL layers (the
  # ledger partitions coverage by tenant, but every layer must isolate its
  # data). Joins, combinations, and the bulk/atomic query paths are always
  # false: they would execute inside a single layer (or bypass the write
  # dispatcher entirely), breaking routing and invalidation — Ash falls back
  # to per-record operations, which flow through us.

  @write_features [:create, :update, :destroy, :upsert, :transact]

  @impl true
  def can?(_resource, {:join, _}), do: false
  def can?(_resource, {:lateral_join, _}), do: false

  # Resource (relationship) aggregates are LOUDLY unsupported: SQL layers
  # build the related subquery via the destination resource's data layer —
  # which is this module, yielding our query struct instead of SQL — so the
  # aggregate would be silently dropped (NotLoaded), the one failure shape
  # this library refuses. Answering false makes Ash raise
  # AggregatesNotSupported at query build instead. Self-aggregation
  # (Ash.count/…) still works via run_aggregate_query; remote-style
  # aggregates arrive as calculations and are unaffected.
  def can?(_resource, {:aggregate, _}), do: false
  def can?(_resource, {:aggregate_relationship, _}), do: false
  def can?(_resource, :combine), do: false
  def can?(_resource, {:combine, _}), do: false
  def can?(_resource, :update_query), do: false
  def can?(_resource, :destroy_query), do: false
  def can?(_resource, {:atomic, _}), do: false
  def can?(_resource, :async_engine), do: false

  def can?(resource, :multitenancy) do
    layers_can?(Info.layer_modules(resource), resource, :multitenancy)
  end

  # Select pushdown is decided by the source of truth alone: layers that
  # can't push selects (Ets) simply return full rows and Ash narrows them,
  # but answering false here would strip query.select entirely — and layers
  # like AshRemote build their wire field list from it (no select = no
  # attributes fetched).
  def can?(resource, :select) do
    case List.last(Info.read_layer_modules(resource)) do
      nil -> false
      layer -> layer.can?(resource, :select)
    end
  end

  def can?(resource, feature) when feature in @write_features do
    layers_can?(Info.write_layer_modules(resource), resource, feature)
  end

  def can?(resource, feature) do
    layers_can?(Info.read_layer_modules(resource), resource, feature)
  end

  defp layers_can?([], _resource, _feature), do: false

  defp layers_can?(layers, resource, feature) do
    Enum.all?(layers, & &1.can?(resource, feature))
  end

  # Transactions only exist when the write path is a single transactional
  # layer (can?(:transact) is the write_order intersection); delegate.
  @impl true
  def transaction(resource, fun, timeout, reason) do
    layer = hd(Info.write_layer_modules(resource))

    if callback?(layer, :transaction, 4) do
      layer.transaction(resource, fun, timeout, reason)
    else
      {:ok, fun.()}
    end
  end

  @impl true
  def rollback(resource, term) do
    layer = hd(Info.write_layer_modules(resource))

    if callback?(layer, :rollback, 2) do
      layer.rollback(resource, term)
    else
      throw({:rollback, term})
    end
  end

  @impl true
  def in_transaction?(resource) do
    layer = hd(Info.write_layer_modules(resource))
    callback?(layer, :in_transaction?, 1) and layer.in_transaction?(resource)
  end

  @impl true
  def prefer_transaction?(_resource), do: false

  defp callback?(layer, name, arity) do
    Code.ensure_loaded?(layer) and function_exported?(layer, name, arity)
  end

  @impl true
  def resource_to_query(resource, domain) do
    %Query{resource: resource, domain: domain}
  end

  # The resource's Ecto schema source (e.g. the Postgres table for inserts)
  # comes from the data layer; delegate to the source of truth. Called during
  # resource compilation, BEFORE verifiers — so it must tolerate invalid
  # layer configuration (the verifier reports it properly afterwards).
  @impl true
  def source(resource) do
    layer = List.last(Info.read_layer_modules(resource))

    if layer && Code.ensure_loaded?(layer) && function_exported?(layer, :source, 1) do
      layer.source(resource)
    else
      ""
    end
  rescue
    _ -> ""
  end

  # --- query building: accumulate into the Query struct -----------------

  @impl true
  def filter(%Query{} = query, filter, _resource) do
    if query.filter do
      {:ok, %{query | filter: Ash.Filter.add_to_filter!(query.filter, filter)}}
    else
      {:ok, %{query | filter: filter}}
    end
  end

  @impl true
  def sort(%Query{} = query, sort, _resource), do: {:ok, %{query | sort: sort}}

  @impl true
  def distinct_sort(%Query{} = query, sort, _resource),
    do: {:ok, %{query | distinct_sort: sort}}

  @impl true
  def distinct(%Query{} = query, distinct, _resource),
    do: {:ok, %{query | distinct: distinct}}

  @impl true
  def limit(%Query{} = query, limit, _resource), do: {:ok, %{query | limit: limit}}

  @impl true
  def offset(%Query{} = query, offset, _resource), do: {:ok, %{query | offset: offset}}

  @impl true
  def select(%Query{} = query, select, _resource), do: {:ok, %{query | select: select}}

  @impl true
  def lock(%Query{} = query, lock_type, _resource), do: {:ok, %{query | lock: lock_type}}

  @impl true
  def set_tenant(_resource, %Query{} = query, tenant), do: {:ok, %{query | tenant: tenant}}

  @impl true
  def set_context(_resource, %Query{} = query, context),
    do: {:ok, %{query | context: context}}

  @impl true
  def add_aggregate(%Query{} = query, aggregate, _resource),
    do: {:ok, %{query | aggregates: query.aggregates ++ [aggregate]}}

  @impl true
  def add_calculation(%Query{} = query, calculation, expression, _resource),
    do: {:ok, %{query | calculations: query.calculations ++ [{calculation, expression}]}}

  # --- reads -------------------------------------------------------------

  @impl true
  def run_query(%Query{} = query, resource) do
    read_layers = Info.read_layer_modules(resource)
    computed? = query.aggregates != [] or query.calculations != []

    cond do
      not KillSwitch.enabled?(resource) ->
        Delegate.run_on_layer(query, List.last(read_layers))

      match?([_], read_layers) ->
        Delegate.run_on_layer(query, hd(read_layers))

      not is_nil(query.lock) ->
        source_read(query, resource, read_layers, :not_cacheable)

      sort_references_uncomputable_calc?(query, resource, hd(read_layers)) ->
        # Sorting on a calc the cache layer can't evaluate (a source-only
        # `remote(...)`) must not be served from the cache — the coverage/merge
        # paths would hand the sort to the cache layer, which can't order by it.
        source_read(query, resource, read_layers, :calc_sort_source_only)

      computed? and not AshMultiDatalayer.ValueMerge.mergeable?(resource) ->
        # Computed values are the source of truth's job; without a mergeable
        # primary key the whole query falls through.
        source_read(query, resource, read_layers, :not_cacheable)

      computed? ->
        merged_read(query, resource, read_layers)

      true ->
        coverage_read(query, resource, read_layers)
    end
  end

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
        source_read(query, resource, read_layers, reason)
    end
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
             List.last(read_layers)
           ) do
        {:ok, merged} ->
          emit_read(:hit, query, resource, started, %{computed_values: computed_tag(source_query)})

          AshMultiDatalayer.Divergence.maybe_sample(query, resource, merged)
          {:ok, merged}

        :stale_cache ->
          # A cached row has no source counterpart (out-of-band delete):
          # abandon the merge, serve everything fresh.
          source_read(query, resource, read_layers, :stale_cache)

        {:error, error} ->
          {:error, error}
      end
    else
      {:miss, reason} -> source_read(query, resource, read_layers, reason)
      {:error, error} -> {:error, error}
    end
  end

  # `:local` when every value was computed from the cache (no source read),
  # `:merged` when the source of truth supplied some calcs/aggregates.
  defp computed_tag(%Query{calculations: [], aggregates: []}), do: :local
  defp computed_tag(%Query{}), do: :merged

  defp source_read(%Query{} = query, resource, read_layers, miss_reason) do
    started = System.monotonic_time()

    with {:ok, records} <- Delegate.run_on_layer(query, List.last(read_layers)) do
      emit_read(:miss, query, resource, started, %{reason: miss_reason})
      maybe_backfill(query, resource, read_layers, records)
      {:ok, records}
    end
  end

  defp maybe_backfill(%Query{} = query, resource, read_layers, records) do
    earlier_layers = Enum.drop(read_layers, -1)

    if Coverage.recordable?(query) and earlier_layers != [] do
      started = System.monotonic_time()

      opts = [
        tenant: query.tenant,
        domain: query.domain,
        fields: Enum.to_list(Coverage.needed_fields(query, resource))
      ]

      case Backfill.upsert_records(earlier_layers, resource, records, opts) do
        :ok ->
          Coverage.record(resource, query.tenant, query)
          emit_read(:backfill, query, resource, started, %{records: length(records)})

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

  @impl true
  def run_aggregate_query(%Query{} = query, aggregates, resource) do
    layer = List.last(Info.read_layer_modules(resource))

    with {:ok, layer_query} <- Delegate.to_layer_query(query, layer) do
      Ash.DataLayer.run_aggregate_query(layer, layer_query, aggregates, resource)
    end
  end

  # --- writes ------------------------------------------------------------

  @impl true
  def create(resource, changeset), do: AshMultiDatalayer.WriteDispatch.create(resource, changeset)

  @impl true
  def update(resource, changeset), do: AshMultiDatalayer.WriteDispatch.update(resource, changeset)

  @impl true
  def destroy(resource, changeset),
    do: AshMultiDatalayer.WriteDispatch.destroy(resource, changeset)

  @impl true
  def upsert(resource, changeset, keys, identity \\ nil),
    do: AshMultiDatalayer.WriteDispatch.upsert(resource, changeset, keys, identity)

  @doc false
  # Invoked by `mix ash.codegen` for resources using this extension: generate
  # Postgres migrations for any postgres-layered multi-datalayer resources.
  def codegen(args) do
    Mix.Task.rerun("ash_multi_datalayer.generate_migrations", args)
  end
end
