defmodule AshMultiDatalayer.Verifiers.ValidateLayers do
  @moduledoc """
  Compile-time validation of the `multi_data_layer` section:

    * layer names are unique
    * `read_order`/`write_order` are non-empty and reference declared layers
    * every layer module implements `Ash.DataLayer`
    * layers whose DSL section has required options (e.g. AshPostgres'
      `postgres` block) must have their extension listed on the resource
    * cache layers must support upserts: every non-last `read_order` layer
      (backfill target) and non-first `write_order` layer (propagation
      target) needs `can?(:upsert)`
  """
  use Spark.Dsl.Verifier

  alias AshMultiDatalayer.DataLayer.Info
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    layers = Info.layers(dsl_state)

    with :ok <- unique_names(dsl_state, layers),
         :ok <- orders_reference_layers(dsl_state, layers),
         :ok <- layers_implement_behaviour(dsl_state, layers),
         :ok <- required_sections_present(dsl_state, layers) do
      upsert_capable_cache_layers(dsl_state)
    end
  end

  defp unique_names(dsl_state, layers) do
    duplicates =
      layers
      |> Enum.frequencies_by(& &1.name)
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    if duplicates == [] do
      :ok
    else
      error(dsl_state, "duplicate layer names: #{inspect(duplicates)}")
    end
  end

  defp orders_reference_layers(dsl_state, layers) do
    declared = MapSet.new(layers, & &1.name)

    Enum.reduce_while([:read_order, :write_order], :ok, fn key, :ok ->
      order = apply(Info, key, [dsl_state])
      unknown = Enum.reject(order, &MapSet.member?(declared, &1))

      cond do
        order == [] ->
          {:halt, error(dsl_state, "#{key} must not be empty")}

        unknown != [] ->
          {:halt,
           error(
             dsl_state,
             "#{key} references undeclared layers #{inspect(unknown)}; " <>
               "declared layers are #{inspect(MapSet.to_list(declared))}"
           )}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp layers_implement_behaviour(dsl_state, layers) do
    Enum.reduce_while(layers, :ok, fn %{name: name, module: module}, :ok ->
      if Spark.implements_behaviour?(module, Ash.DataLayer) do
        {:cont, :ok}
      else
        {:halt,
         error(
           dsl_state,
           "layer #{inspect(name)} module #{inspect(module)} does not implement Ash.DataLayer"
         )}
      end
    end)
  end

  # A layer whose Spark DSL section carries REQUIRED options (like AshPostgres'
  # repo) can't work without its section configured — which needs its
  # extension on the resource. Layers with optional-only sections (like Ets)
  # work from defaults and are not required.
  defp required_sections_present(dsl_state, layers) do
    extensions = Verifier.get_persisted(dsl_state, :extensions, [])

    layers
    |> Enum.filter(&section_required?(&1.module))
    |> Enum.reject(&(&1.module in extensions))
    |> case do
      [] ->
        :ok

      [%{name: name, module: module} | _] ->
        error(
          dsl_state,
          "layer #{inspect(name)} (#{inspect(module)}) requires its DSL section " <>
            "to be configured. Add the extension to the resource:\n\n" <>
            "    use Ash.Resource,\n" <>
            "      data_layer: AshMultiDatalayer.DataLayer,\n" <>
            "      extensions: [#{inspect(module)}]\n"
        )
    end
  end

  defp section_required?(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :sections, 0) and
      Enum.any?(module.sections(), fn section ->
        Enum.any?(section.schema, fn {_key, opts} -> opts[:required] end)
      end)
  end

  defp upsert_capable_cache_layers(dsl_state) do
    read_targets = dsl_state |> Info.read_layer_modules() |> Enum.drop(-1)
    write_targets = dsl_state |> Info.write_layer_modules() |> Enum.drop(1)

    (read_targets ++ write_targets)
    |> Enum.uniq()
    |> Enum.reject(&layer_can?(&1, dsl_state, :upsert))
    |> case do
      [] ->
        :ok

      [module | _] ->
        error(
          dsl_state,
          "#{inspect(module)} is a backfill/propagation target (a non-last " <>
            "read_order or non-first write_order layer) but does not support " <>
            "upserts. Cache layers must support :upsert"
        )
    end
  end

  defp layer_can?(module, dsl_state, feature) do
    module.can?(dsl_state, feature)
  rescue
    _ -> false
  end

  defp error(dsl_state, message) do
    {:error,
     Spark.Error.DslError.exception(
       module: Verifier.get_persisted(dsl_state, :module),
       path: [:multi_data_layer],
       message: message
     )}
  end
end
