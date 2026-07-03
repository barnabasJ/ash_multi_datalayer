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
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@multi_data_layer],
    verifiers: []

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
  end

  require Logger

  alias AshMultiDatalayer.Backfill
  alias AshMultiDatalayer.Coverage
  alias AshMultiDatalayer.DataLayer.Info
  alias AshMultiDatalayer.Delegate
  alias AshMultiDatalayer.KillSwitch
  alias AshMultiDatalayer.Telemetry

  # Interim capability answer: the intersection of all declared layers.
  # Refined per read_order/write_order in the capability-negotiation phase.
  @impl true
  def can?(resource, feature) do
    case Info.layer_modules(resource) do
      [] -> false
      modules -> Enum.all?(modules, & &1.can?(resource, feature))
    end
  end

  @impl true
  def resource_to_query(resource, domain) do
    %Query{resource: resource, domain: domain}
  end

  # The resource's Ecto schema source (e.g. the Postgres table for inserts)
  # comes from the data layer; delegate to the source of truth.
  @impl true
  def source(resource) do
    layer = List.last(Info.read_layer_modules(resource))

    if Code.ensure_loaded?(layer) and function_exported?(layer, :source, 1) do
      layer.source(resource)
    else
      ""
    end
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

    cond do
      not KillSwitch.enabled?(resource) ->
        Delegate.run_on_layer(query, List.last(read_layers))

      match?([_], read_layers) ->
        Delegate.run_on_layer(query, hd(read_layers))

      not servable_from_coverage?(query) ->
        # Aggregates/calculations/locks are computed by the source of truth
        # and are never cache-eligible.
        source_read(query, resource, read_layers, :not_cacheable)

      true ->
        coverage_read(query, resource, read_layers)
    end
  end

  # Limited/offset/distinct probes can still be SERVED by recorded unlimited
  # coverage (the cache layer holds the complete matching set and applies
  # sort/limit/offset itself); aggregate/calc/lock queries cannot.
  defp servable_from_coverage?(%Query{} = query) do
    query.aggregates == [] and query.calculations == [] and is_nil(query.lock)
  end

  defp coverage_read(%Query{} = query, resource, read_layers) do
    started = System.monotonic_time()

    case Coverage.covers?(resource, query.tenant, query) do
      {:ok, _entry} ->
        with {:ok, records} <- Delegate.run_on_layer(query, hd(read_layers)) do
          emit_read(:hit, query, resource, started)
          {:ok, records}
        end

      {:miss, reason} ->
        source_read(query, resource, read_layers, reason)
    end
  end

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

  defp emit_read(kind, query, resource, started, extra \\ %{}) do
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
