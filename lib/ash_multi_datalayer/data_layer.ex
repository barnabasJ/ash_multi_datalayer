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

  Routing *policy* — which layer serves a read, how a write propagates, which
  layer is authoritative — lives behind the `AshMultiDatalayer.Orchestrator`
  behaviour, selected per resource with the `orchestrator` option (default
  `AshMultiDatalayer.Orchestrator.ProvenCoverage`, today's coverage-ledger
  behaviour). This module is a thin shell: it accumulates Ash's canonical query
  build into a `Query` struct, keeps the migration/codegen shim, and answers
  Ash's structural callbacks by delegating to the configured orchestrator. See
  the orchestrator-behaviour ADR.
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
      orchestrator: [
        type: {:spark_behaviour, AshMultiDatalayer.Orchestrator},
        doc: """
        The orchestration strategy: a module implementing
        `AshMultiDatalayer.Orchestrator`, optionally with opts
        (`{Module, opts}`). Defaults to
        `AshMultiDatalayer.Orchestrator.ProvenCoverage` — today's coverage-ledger
        behaviour. The strategy decides which layer serves a read, how writes
        propagate, and which layer is authoritative.
        """
      ],
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
      ],
      fold_aggregates?: [
        type: :boolean,
        default: true,
        doc: """
        Whether a loaded relationship aggregate (`count :todos`, …) is computed
        by loading its related rows through this layer's own read path and
        folding them in memory, instead of asking the source of truth. On by
        default: when the ledger proves the related rows are covered the
        aggregate costs 0 source reads, and it works for any source (no in-DB
        join over the related resource is required — see the relationship-
        aggregates ADR). Soundness is inherited from the read path, which always
        returns the complete related set (cache when covered, source otherwise).

        Turn this off to restore refusing aggregates (a loud
        `AggregatesNotSupported` at query build).
        """
      ],
      fold_aggregate_overrides: [
        type: {:list, :atom},
        default: [],
        doc: """
        Aggregate names never folded locally even when `fold_aggregates?` is on
        — the per-aggregate escape hatch (sent to the source of truth instead).
        """
      ],
      sql_join_aggregates?: [
        type: :boolean,
        default: true,
        doc: """
        Whether a relationship aggregate whose related resource's source of
        truth is a SQL layer in the **same repo** as this one is computed as an
        in-database join by the source, instead of folded from the related rows.
        On by default: a folded `COUNT` materialises every related row into
        memory to count it (the cache layer is a row store — it folds too, so a
        cache hit does not avoid this), which is unbounded for a large
        relationship. A same-repo SQL join computes the count in the database
        with bounded memory, so it is the safer default (see the relationship-
        aggregates ADR, option 3).

        Unlike folding, the join is a source read — it bypasses the cache (a
        DB-side `COUNT`, not a 0-RPC fold). Turn this off (or use
        `sql_join_aggregate_overrides`) to fold a small, hot relationship from
        the cache instead. Relationship aggregates over a non-SQL or different-
        repo related resource always fold — they cannot be joined.
        """
      ],
      sql_join_aggregate_overrides: [
        type: {:list, :atom},
        default: [],
        doc: """
        Relationship-aggregate names folded from the related rows even when
        `sql_join_aggregates?` is on — the per-aggregate escape hatch for a
        small, hot relationship you would rather serve 0-RPC from the cache than
        round-trip to the database.
        """
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@multi_data_layer],
    verifiers: [
      AshMultiDatalayer.Verifiers.ValidateOrchestrator,
      AshMultiDatalayer.Verifiers.ValidateLayers,
      AshMultiDatalayer.Verifiers.ValidateMultitenancy,
      AshMultiDatalayer.Verifiers.ValidateAggregateOverrides,
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

  alias AshMultiDatalayer.DataLayer.Info
  alias AshMultiDatalayer.Delegate
  alias AshMultiDatalayer.SqlPassthrough
  alias AshMultiDatalayer.Telemetry

  # --- capabilities --------------------------------------------------------
  #
  # `can?/2` routes through the configured orchestrator, which either answers a
  # boolean or returns `:default` to fall back to the shell's intersection
  # semantics below (kept verbatim in Phase 1; the per-strategy derivation moves
  # into the strategies in Phase 4a). The transitional defaults:
  #
  # Read features answer from the intersection of read_order layers, write
  # features from write_order layers, multitenancy from ALL layers (the ledger
  # partitions coverage by tenant, but every layer must isolate its data).
  # Joins, combinations, and the bulk/atomic query paths are always false: they
  # would execute inside a single layer (or bypass the write dispatcher
  # entirely), breaking routing and invalidation — Ash falls back to per-record
  # operations, which flow through us.

  @write_features [:create, :update, :destroy, :upsert, :transact]

  # Relationship-aggregate kinds we advertise support for (see
  # `AshMultiDatalayer.Orchestrator.ProvenCoverage`, which computes them).
  # `:custom` is excluded — it carries a module implementation we don't run.
  @foldable_aggregate_kinds [:count, :sum, :avg, :min, :max, :first, :list, :exists]

  # Relationship aggregates are supported when at least one mechanism is enabled.
  defp aggregates_supported?(resource) do
    Info.fold_aggregates?(resource) or Info.sql_join_aggregates?(resource)
  end

  @impl true
  def can?(resource, feature) do
    {orchestrator, _opts} = Info.orchestrator(resource)

    case orchestrator.can?(resource, feature) do
      :default -> default_can?(resource, feature)
      answer when is_boolean(answer) -> answer
    end
  end

  defp default_can?(_resource, {:join, _}), do: false
  defp default_can?(_resource, {:lateral_join, _}), do: false

  # Relationship aggregates are computed one of two ways (see the aggregates
  # ADR): a same-repo SQL relationship is joined in the database by the source
  # (`SqlPassthrough`, gated by `sql_join_aggregates?`); everything else is
  # folded from the related rows MDL loads through its own read path (cache when
  # covered → 0 source reads, source otherwise; gated by `fold_aggregates?`). So
  # we advertise support for the foldable kinds whenever either mechanism is on.
  # With both off, we answer false → Ash raises AggregatesNotSupported (loud) at
  # query build.
  defp default_can?(resource, {:aggregate, kind}) do
    aggregates_supported?(resource) and kind in @foldable_aggregate_kinds
  end

  defp default_can?(resource, {:aggregate_relationship, _}), do: aggregates_supported?(resource)
  defp default_can?(_resource, :combine), do: false
  defp default_can?(_resource, {:combine, _}), do: false
  defp default_can?(_resource, :update_query), do: false
  defp default_can?(_resource, :destroy_query), do: false
  defp default_can?(_resource, {:atomic, _}), do: false
  defp default_can?(_resource, :async_engine), do: false

  defp default_can?(resource, :multitenancy) do
    layers_can?(Info.layer_modules(resource), resource, :multitenancy)
  end

  # Select pushdown is decided by the source of truth alone: layers that
  # can't push selects (Ets) simply return full rows and Ash narrows them,
  # but answering false here would strip query.select entirely — and layers
  # like AshRemote build their wire field list from it (no select = no
  # attributes fetched).
  defp default_can?(resource, :select) do
    case List.last(Info.read_layer_modules(resource)) do
      nil -> false
      layer -> layer.can?(resource, :select)
    end
  end

  defp default_can?(resource, feature) when feature in @write_features do
    layers_can?(Info.write_layer_modules(resource), resource, feature)
  end

  defp default_can?(resource, feature) do
    layers_can?(Info.read_layer_modules(resource), resource, feature)
  end

  defp layers_can?([], _resource, _feature), do: false

  defp layers_can?(layers, resource, feature) do
    Enum.all?(layers, & &1.can?(resource, feature))
  end

  # --- structural callbacks: delegate authority to the orchestrator ------

  # Transactions are the transaction layer's (the orchestrator's authoritative
  # write layer); delegate.
  @impl true
  def transaction(resource, fun, timeout, reason) do
    layer = transaction_layer(resource)

    if callback?(layer, :transaction, 4) do
      layer.transaction(resource, fun, timeout, reason)
    else
      # A layer without its own transaction callback has no real transaction
      # to run `fun` in — but `rollback/2`'s own fallback (below) still
      # signals failure the idiomatic Ash way, `throw({:rollback, term})`
      # (mirroring `Ecto.Repo.transaction/2`). Nothing here caught that throw
      # (M-8): it escaped as an uncaught `nocatch` crash instead of the
      # `{:error, term}` a real transaction callback would return.
      try do
        {:ok, fun.()}
      catch
        :throw, {:rollback, term} -> {:error, term}
      end
    end
  end

  @impl true
  def rollback(resource, term) do
    layer = transaction_layer(resource)

    if callback?(layer, :rollback, 2) do
      layer.rollback(resource, term)
    else
      throw({:rollback, term})
    end
  end

  @impl true
  def in_transaction?(resource) do
    layer = transaction_layer(resource)
    callback?(layer, :in_transaction?, 1) and layer.in_transaction?(resource)
  end

  @impl true
  def prefer_transaction?(_resource), do: false

  defp transaction_layer(resource) do
    {orchestrator, _opts} = Info.orchestrator(resource)
    orchestrator.transaction_layer(resource)
  end

  defp callback?(layer, name, arity) do
    Code.ensure_loaded?(layer) and function_exported?(layer, name, arity)
  end

  @impl true
  def resource_to_query(resource, domain) do
    %Query{resource: resource, domain: domain}
  end

  # The resource's Ecto schema source (e.g. the Postgres table for inserts)
  # comes from the orchestrator's authority layer. Called during resource
  # compilation, BEFORE verifiers — so it must tolerate invalid layer
  # configuration (the verifier reports it properly afterwards).
  @impl true
  def source(resource) do
    {orchestrator, _opts} = Info.orchestrator(resource)
    layer = orchestrator.authority(resource)

    if layer && Code.ensure_loaded?(layer) && function_exported?(layer, :source, 1) do
      layer.source(resource)
    else
      ""
    end
  rescue
    _ -> ""
  end

  # --- query building: accumulate into the Query struct -----------------

  # Every build callback has a second head for the SQL-passthrough query
  # (`set_context/3` flips into it inside an aggregate subquery — see below).
  # It forwards verbatim to the SQL source layer, whose return is exactly what
  # this callback must return, so ash_sql receives its own `%Ecto.Query{}` at
  # the end of the build. Only `filter`/`set_tenant`/`add_aggregate`/
  # `add_calculation` fire in practice (subqueries unset the rest), but covering
  # all of them is cheap and robust.

  @impl true
  def filter(%Query{} = query, filter, _resource) do
    if query.filter do
      {:ok, %{query | filter: Ash.Filter.add_to_filter!(query.filter, filter)}}
    else
      {:ok, %{query | filter: filter}}
    end
  end

  def filter(%{__ash_bindings__: _} = passthrough, filter, resource),
    do: Ash.DataLayer.filter(SqlPassthrough.layer(resource), passthrough, filter, resource)

  @impl true
  def sort(%Query{} = query, sort, _resource), do: {:ok, %{query | sort: sort}}

  def sort(%{__ash_bindings__: _} = passthrough, sort, resource),
    do: SqlPassthrough.layer(resource).sort(passthrough, sort, resource)

  @impl true
  def distinct_sort(%Query{} = query, sort, _resource),
    do: {:ok, %{query | distinct_sort: sort}}

  def distinct_sort(%{__ash_bindings__: _} = passthrough, sort, resource),
    do: SqlPassthrough.layer(resource).distinct_sort(passthrough, sort, resource)

  @impl true
  def distinct(%Query{} = query, distinct, _resource),
    do: {:ok, %{query | distinct: distinct}}

  def distinct(%{__ash_bindings__: _} = passthrough, distinct, resource),
    do: SqlPassthrough.layer(resource).distinct(passthrough, distinct, resource)

  @impl true
  def limit(%Query{} = query, limit, _resource), do: {:ok, %{query | limit: limit}}

  def limit(%{__ash_bindings__: _} = passthrough, limit, resource),
    do: SqlPassthrough.layer(resource).limit(passthrough, limit, resource)

  @impl true
  def offset(%Query{} = query, offset, _resource), do: {:ok, %{query | offset: offset}}

  def offset(%{__ash_bindings__: _} = passthrough, offset, resource),
    do: SqlPassthrough.layer(resource).offset(passthrough, offset, resource)

  @impl true
  def select(%Query{} = query, select, _resource), do: {:ok, %{query | select: select}}

  def select(%{__ash_bindings__: _} = passthrough, select, resource),
    do: SqlPassthrough.layer(resource).select(passthrough, select, resource)

  @impl true
  def lock(%Query{} = query, lock_type, _resource), do: {:ok, %{query | lock: lock_type}}

  def lock(%{__ash_bindings__: _} = passthrough, lock_type, resource),
    do: SqlPassthrough.layer(resource).lock(passthrough, lock_type, resource)

  @impl true
  def set_tenant(_resource, %Query{} = query, tenant), do: {:ok, %{query | tenant: tenant}}

  def set_tenant(resource, %{__ash_bindings__: _} = passthrough, tenant),
    do: SqlPassthrough.layer(resource).set_tenant(resource, passthrough, tenant)

  # The only callback guaranteed to fire for every aggregate subquery. When
  # ash_sql's `parent_bindings` signal is present and the related resource's
  # source of truth is a same-repo SQL layer, flip into passthrough by returning
  # that layer's `%Ecto.Query{}` (built with the same context, so ash_sql's
  # binding handshake lines up). A top-level read carries no `parent_bindings`
  # and stores the context as before.
  #
  # Whether the flip is even attempted is an orchestrator question: only
  # strategies that declare SQL passthrough support (ProvenCoverage) can be
  # spliced as an in-DB aggregate subquery. A strategy with a complete,
  # authoritative local layer (LocalOutbox) never participates.
  @impl true
  def set_context(resource, %Query{} = query, context) do
    if sql_passthrough?(resource) do
      case SqlPassthrough.build(resource, query.domain, context) do
        :not_a_subquery -> {:ok, %{query | context: context}}
        {:ok, ecto_query} -> {:ok, ecto_query}
        {:error, error} -> {:error, error}
      end
    else
      {:ok, %{query | context: context}}
    end
  end

  # Does the configured orchestrator participate in ash_sql aggregate-subquery
  # passthrough? Optional strategy hook; strategies that don't define it (or
  # answer false) never flip into the SQL layer's query.
  defp sql_passthrough?(resource) do
    {orchestrator, _opts} = Info.orchestrator(resource)

    Code.ensure_loaded?(orchestrator) and
      function_exported?(orchestrator, :sql_passthrough?, 1) and
      orchestrator.sql_passthrough?(resource)
  end

  @impl true
  def add_aggregate(%Query{} = query, aggregate, _resource),
    do: {:ok, %{query | aggregates: query.aggregates ++ [aggregate]}}

  def add_aggregate(%{__ash_bindings__: _} = passthrough, aggregate, resource),
    do:
      Ash.DataLayer.add_aggregates(
        SqlPassthrough.layer(resource),
        passthrough,
        [aggregate],
        resource
      )

  @impl true
  def add_calculation(%Query{} = query, calculation, expression, _resource),
    do: {:ok, %{query | calculations: query.calculations ++ [{calculation, expression}]}}

  def add_calculation(%{__ash_bindings__: _} = passthrough, calculation, expression, resource),
    do:
      Ash.DataLayer.add_calculations(
        SqlPassthrough.layer(resource),
        passthrough,
        [{calculation, expression}],
        resource
      )

  # --- data path: delegate to the orchestrator ---------------------------

  @impl true
  def run_query(%Query{} = query, resource) do
    case forced_read_layer(query) do
      nil ->
        {orchestrator, _opts} = Info.orchestrator(resource)
        orchestrator.read(query, resource)

      layer_name ->
        # `read_from:` escape hatch — route the query raw to the named layer,
        # strategy-independent and **side-effect-free** (no coverage recording,
        # backfill, LRU touch, or outbox interaction). A compare-read observes,
        # never perturbs. See the LocalOutbox RFC's "Per-action layer targeting".
        layer = Info.layer!(resource, layer_name)
        Telemetry.read(:forced, resource, query, %{}, %{layer: layer_name})
        Delegate.run_on_layer(query, layer)
    end
  end

  defp forced_read_layer(%Query{context: context}) when is_map(context) do
    context |> Map.get(:multi_datalayer, %{}) |> Map.get(:read_from)
  end

  defp forced_read_layer(_query), do: nil

  @impl true
  def run_aggregate_query(%Query{} = query, aggregates, resource) do
    {orchestrator, _opts} = Info.orchestrator(resource)
    orchestrator.run_aggregate_query(query, aggregates, resource)
  end

  @impl true
  def create(resource, changeset) do
    {orchestrator, _opts} = Info.orchestrator(resource)
    orchestrator.create(resource, changeset)
  end

  @impl true
  def update(resource, changeset) do
    {orchestrator, _opts} = Info.orchestrator(resource)
    orchestrator.update(resource, changeset)
  end

  @impl true
  def destroy(resource, changeset) do
    {orchestrator, _opts} = Info.orchestrator(resource)
    orchestrator.destroy(resource, changeset)
  end

  @impl true
  def upsert(resource, changeset, keys, identity \\ nil) do
    {orchestrator, _opts} = Info.orchestrator(resource)
    orchestrator.upsert(resource, changeset, keys, identity)
  end

  @doc false
  # Invoked by `mix ash.codegen` for resources using this extension: generate
  # Postgres migrations for any postgres-layered multi-datalayer resources.
  def codegen(args) do
    Mix.Task.rerun("ash_multi_datalayer.generate_migrations", args)
  end
end
