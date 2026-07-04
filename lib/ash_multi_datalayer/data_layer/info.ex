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

  @doc "Maximum coverage-ledger entries per resource+tenant before LRU eviction."
  @spec ledger_max_entries(Ash.Resource.t() | Spark.Dsl.t()) :: pos_integer()
  def ledger_max_entries(resource) do
    Extension.get_opt(resource, [:multi_data_layer], :ledger_max_entries, 10_000)
  end

  @doc "Fraction of coverage-hit reads shadow-checked against the last read layer."
  @spec divergence_sampler(Ash.Resource.t() | Spark.Dsl.t()) :: float()
  def divergence_sampler(resource) do
    Extension.get_opt(resource, [:multi_data_layer], :divergence_sampler, 0.0)
  end

  @doc "Whether cache-evaluable calculations are computed locally instead of from the source."
  @spec local_evaluation?(Ash.Resource.t() | Spark.Dsl.t()) :: boolean()
  def local_evaluation?(resource) do
    Extension.get_opt(resource, [:multi_data_layer], :local_evaluation?, true)
  end

  @doc "Calculation names always computed by the source of truth (local-evaluation escape hatch)."
  @spec local_evaluation_overrides(Ash.Resource.t() | Spark.Dsl.t()) :: [atom()]
  def local_evaluation_overrides(resource) do
    Extension.get_opt(resource, [:multi_data_layer], :local_evaluation_overrides, [])
  end

  @doc "Whether relationship aggregates are folded from cached related rows instead of the source."
  @spec fold_aggregates?(Ash.Resource.t() | Spark.Dsl.t()) :: boolean()
  def fold_aggregates?(resource) do
    Extension.get_opt(resource, [:multi_data_layer], :fold_aggregates?, true)
  end

  @doc "Aggregate names never folded locally (fold-aggregates escape hatch)."
  @spec fold_aggregate_overrides(Ash.Resource.t() | Spark.Dsl.t()) :: [atom()]
  def fold_aggregate_overrides(resource) do
    Extension.get_opt(resource, [:multi_data_layer], :fold_aggregate_overrides, [])
  end
end
