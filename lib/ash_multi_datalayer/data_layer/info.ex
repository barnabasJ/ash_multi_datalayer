defmodule AshMultiDatalayer.DataLayer.Info do
  @moduledoc """
  Introspection for the `multi_data_layer` DSL section.
  """

  alias AshMultiDatalayer.Layer
  alias Spark.Dsl.Extension

  @doc "All declared layers, in declaration order."
  @spec layers(Ash.Resource.t() | Spark.Dsl.t()) :: [Layer.t()]
  def layers(resource) do
    Extension.get_entities(resource, [:multi_data_layer])
  end

  @doc "The modules of all declared layers, in declaration order."
  @spec layer_modules(Ash.Resource.t() | Spark.Dsl.t()) :: [module()]
  def layer_modules(resource) do
    resource |> layers() |> Enum.map(& &1.module)
  end

  @doc "The module for the layer named `name`. Raises if not declared."
  @spec layer!(Ash.Resource.t() | Spark.Dsl.t(), atom()) :: module()
  def layer!(resource, name) do
    case Enum.find(layers(resource), &(&1.name == name)) do
      %Layer{module: module} ->
        module

      nil ->
        raise ArgumentError,
              "no layer named #{inspect(name)} declared in the multi_data_layer section"
    end
  end

  @doc "The declared read order (layer names)."
  @spec read_order(Ash.Resource.t() | Spark.Dsl.t()) :: [atom()]
  def read_order(resource) do
    Extension.get_opt(resource, [:multi_data_layer], :read_order, [])
  end

  @doc "The declared write order (layer names)."
  @spec write_order(Ash.Resource.t() | Spark.Dsl.t()) :: [atom()]
  def write_order(resource) do
    Extension.get_opt(resource, [:multi_data_layer], :write_order, [])
  end

  @doc "The layer modules in read order."
  @spec read_layer_modules(Ash.Resource.t() | Spark.Dsl.t()) :: [module()]
  def read_layer_modules(resource) do
    resource |> read_order() |> Enum.map(&layer!(resource, &1))
  end

  @doc "The layer modules in write order."
  @spec write_layer_modules(Ash.Resource.t() | Spark.Dsl.t()) :: [module()]
  def write_layer_modules(resource) do
    resource |> write_order() |> Enum.map(&layer!(resource, &1))
  end

  @default_orchestrator AshMultiDatalayer.Orchestrator.ProvenCoverage

  # The ProvenCoverage-specific section keys, retained in Phase 1 as
  # section-level *aliases* that forward into ProvenCoverage's orchestrator opts
  # (so existing declarations and DSL tests compile/pass unchanged). Phase 4a
  # removes them, rewriting declarations to `orchestrator {ProvenCoverage, ...}`.
  @proven_coverage_alias_defaults [
    ledger_max_entries: 10_000,
    divergence_sampler: 0.0,
    local_evaluation?: true,
    local_evaluation_overrides: [],
    fold_aggregates?: true,
    fold_aggregate_overrides: [],
    sql_join_aggregates?: true,
    sql_join_aggregate_overrides: []
  ]

  @doc """
  The configured orchestrator as `{module, opts}`.

  Defaults to `AshMultiDatalayer.Orchestrator.ProvenCoverage`. For
  ProvenCoverage, the retained section-level alias keys (`divergence_sampler`,
  `ledger_max_entries`, …) are forwarded into its opts as defaults, with any
  explicit orchestrator opts taking precedence.
  """
  @spec orchestrator(Ash.Resource.t() | Spark.Dsl.t()) :: {module(), keyword()}
  def orchestrator(resource) do
    {module, opts} =
      case Extension.get_opt(resource, [:multi_data_layer], :orchestrator, nil) do
        nil -> {@default_orchestrator, []}
        {mod, mod_opts} when is_atom(mod) and is_list(mod_opts) -> {mod, mod_opts}
        mod when is_atom(mod) -> {mod, []}
      end

    if module == @default_orchestrator do
      {module, Keyword.merge(forwarded_alias_opts(resource), opts)}
    else
      {module, opts}
    end
  end

  @doc "Whether the resource is configured with the ProvenCoverage orchestrator."
  @spec proven_coverage?(Ash.Resource.t() | Spark.Dsl.t()) :: boolean()
  def proven_coverage?(resource) do
    match?({@default_orchestrator, _opts}, orchestrator(resource))
  end

  defp forwarded_alias_opts(resource) do
    for {key, default} <- @proven_coverage_alias_defaults do
      {key, Extension.get_opt(resource, [:multi_data_layer], key, default)}
    end
  end

  # These getters re-route through `orchestrator/1` so ProvenCoverage's opts are
  # the single source of truth whether declared via the section aliases (Phase 1)
  # or via `orchestrator {ProvenCoverage, ...}` opts (the Phase 4a end state).
  defp proven_coverage_opt(resource, key, default) do
    {_module, opts} = orchestrator(resource)
    Keyword.get(opts, key, default)
  end

  @doc "Maximum coverage-ledger entries per resource+tenant before LRU eviction."
  @spec ledger_max_entries(Ash.Resource.t() | Spark.Dsl.t()) :: pos_integer()
  def ledger_max_entries(resource) do
    proven_coverage_opt(resource, :ledger_max_entries, 10_000)
  end

  @doc "Fraction of coverage-hit reads shadow-checked against the last read layer."
  @spec divergence_sampler(Ash.Resource.t() | Spark.Dsl.t()) :: float()
  def divergence_sampler(resource) do
    proven_coverage_opt(resource, :divergence_sampler, 0.0)
  end

  @doc "Whether cache-evaluable calculations are computed locally instead of from the source."
  @spec local_evaluation?(Ash.Resource.t() | Spark.Dsl.t()) :: boolean()
  def local_evaluation?(resource) do
    proven_coverage_opt(resource, :local_evaluation?, true)
  end

  @doc "Calculation names always computed by the source of truth (local-evaluation escape hatch)."
  @spec local_evaluation_overrides(Ash.Resource.t() | Spark.Dsl.t()) :: [atom()]
  def local_evaluation_overrides(resource) do
    proven_coverage_opt(resource, :local_evaluation_overrides, [])
  end

  @doc "Whether relationship aggregates are folded from cached related rows instead of the source."
  @spec fold_aggregates?(Ash.Resource.t() | Spark.Dsl.t()) :: boolean()
  def fold_aggregates?(resource) do
    proven_coverage_opt(resource, :fold_aggregates?, true)
  end

  @doc "Aggregate names never folded locally (fold-aggregates escape hatch)."
  @spec fold_aggregate_overrides(Ash.Resource.t() | Spark.Dsl.t()) :: [atom()]
  def fold_aggregate_overrides(resource) do
    proven_coverage_opt(resource, :fold_aggregate_overrides, [])
  end

  @doc "Whether same-repo SQL relationship aggregates are computed as an in-DB join by default."
  @spec sql_join_aggregates?(Ash.Resource.t() | Spark.Dsl.t()) :: boolean()
  def sql_join_aggregates?(resource) do
    proven_coverage_opt(resource, :sql_join_aggregates?, true)
  end

  @doc "Relationship-aggregate names folded from the cache instead of joined in SQL (opt-out)."
  @spec sql_join_aggregate_overrides(Ash.Resource.t() | Spark.Dsl.t()) :: [atom()]
  def sql_join_aggregate_overrides(resource) do
    proven_coverage_opt(resource, :sql_join_aggregate_overrides, [])
  end
end
