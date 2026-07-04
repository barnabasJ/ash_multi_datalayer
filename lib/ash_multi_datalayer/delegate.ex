defmodule AshMultiDatalayer.Delegate do
  @moduledoc """
  Replays an accumulated `AshMultiDatalayer.DataLayer.Query` onto an
  underlying layer.

  The replay follows Ash's canonical data-layer query build order
  (`Ash.Query.data_layer_query/2`): resource_to_query → set_context →
  set_tenant → select → sort → distinct_sort → add_aggregates → filter →
  add_calculations → distinct → limit → offset → lock. Optional callbacks the
  layer doesn't export are skipped exactly where Ash itself would skip them;
  semantic steps (filter/sort/limit/…) with a value the layer cannot take
  are an error — our `can?/2` should have prevented Ash from building such a
  query in the first place.
  """

  alias AshMultiDatalayer.DataLayer.Query

  @doc "Builds the layer's query from ours and runs it."
  @spec run_on_layer(Query.t() | struct(), module()) ::
          {:ok, [Ash.Resource.record()]} | {:error, term()}
  def run_on_layer(%Query{} = query, layer) do
    with {:ok, layer_query} <- to_layer_query(query, layer),
         {:ok, layer_query} <- return_query(layer, layer_query, query.resource) do
      Ash.DataLayer.run_query(layer, layer_query, query.resource)
    end
  end

  # The final build step Ash's own read pipeline runs before executing a query
  # (`Ash.Query.data_layer_query/2`): it lets a layer finalise the query — for
  # ash_sql layers this is where `load_aggregates` become real SELECTs/joins, so
  # a delegated aggregate read must run it too. Layers without the callback (Ets)
  # skip it.
  defp return_query(layer, layer_query, resource) do
    if callback?(layer, :return_query, 2) do
      Ash.DataLayer.return_query(layer, layer_query, resource)
    else
      {:ok, layer_query}
    end
  end

  @doc "Replays the accumulated query onto `layer`, returning the layer's query."
  @spec to_layer_query(Query.t() | struct(), module()) :: {:ok, term()} | {:error, term()}
  def to_layer_query(%Query{resource: resource} = query, layer) do
    layer_query = Ash.DataLayer.resource_to_query(layer, resource, query.domain)

    with {:ok, layer_query} <- set_context(layer, resource, layer_query, query.context),
         {:ok, layer_query} <- set_tenant(layer, resource, layer_query, query.tenant),
         {:ok, layer_query} <- step(layer, :select, [layer_query, query.select, resource]),
         {:ok, layer_query} <- step(layer, :sort, [layer_query, query.sort, resource]),
         {:ok, layer_query} <-
           step(layer, :distinct_sort, [layer_query, query.distinct_sort, resource]),
         {:ok, layer_query} <- add_aggregates(layer, layer_query, query.aggregates, resource),
         {:ok, layer_query} <- apply_filter(layer, layer_query, query.filter, resource),
         {:ok, layer_query} <-
           add_calculations(layer, layer_query, query.calculations, resource),
         {:ok, layer_query} <- step(layer, :distinct, [layer_query, query.distinct, resource]),
         {:ok, layer_query} <- step(layer, :limit, [layer_query, query.limit, resource]),
         {:ok, layer_query} <- step(layer, :offset, [layer_query, query.offset, resource]) do
      step(layer, :lock, [layer_query, query.lock, resource])
    end
  end

  # Steps with no value to apply are always skipped; steps whose callback the
  # layer doesn't export are skipped only when the value is empty-equivalent
  # or the step is a pure optimisation (select: a layer that can't push it
  # returns full rows and Ash narrows them) — and an error otherwise.
  defp step(layer, callback, [layer_query, value, resource]) do
    cond do
      empty_value?(callback, value) ->
        {:ok, layer_query}

      callback?(layer, callback, 3) ->
        apply(layer, callback, [layer_query, value, resource])

      callback == :select ->
        {:ok, layer_query}

      true ->
        {:error,
         "#{inspect(layer)} does not support #{callback} but the query requires it " <>
           "(value: #{inspect(value)})"}
    end
  end

  defp empty_value?(_callback, nil), do: true
  defp empty_value?(callback, []) when callback in [:sort, :distinct], do: true
  defp empty_value?(:offset, 0), do: true
  defp empty_value?(_callback, _value), do: false

  defp set_context(layer, resource, layer_query, context) do
    if callback?(layer, :set_context, 3) do
      layer.set_context(resource, layer_query, context || %{})
    else
      {:ok, layer_query}
    end
  end

  defp set_tenant(_layer, _resource, layer_query, nil), do: {:ok, layer_query}

  defp set_tenant(layer, resource, layer_query, tenant) do
    if callback?(layer, :set_tenant, 3) do
      layer.set_tenant(resource, layer_query, tenant)
    else
      {:ok, layer_query}
    end
  end

  defp apply_filter(_layer, layer_query, nil, _resource), do: {:ok, layer_query}

  defp apply_filter(layer, layer_query, filter, resource) do
    cond do
      not Ash.DataLayer.can?(layer, resource, :filter) ->
        {:error, "#{inspect(layer)} does not support filtering"}

      Ash.DataLayer.can?(layer, resource, :boolean_filter) ->
        Ash.DataLayer.filter(layer, layer_query, filter, resource)

      true ->
        simple_filter = Ash.Filter.to_simple_filter(filter)
        Ash.DataLayer.filter(layer, layer_query, simple_filter, resource)
    end
  end

  defp add_aggregates(_layer, layer_query, [], _resource), do: {:ok, layer_query}

  defp add_aggregates(layer, layer_query, aggregates, resource) do
    if callback?(layer, :add_aggregates, 3) do
      Ash.DataLayer.add_aggregates(layer, layer_query, aggregates, resource)
    else
      Enum.reduce_while(aggregates, {:ok, layer_query}, fn aggregate, {:ok, acc} ->
        case Ash.DataLayer.add_aggregate(layer, acc, aggregate, resource) do
          {:ok, acc} -> {:cont, {:ok, acc}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end
  end

  defp add_calculations(_layer, layer_query, [], _resource), do: {:ok, layer_query}

  defp add_calculations(layer, layer_query, calculations, resource) do
    if callback?(layer, :add_calculations, 3) do
      Ash.DataLayer.add_calculations(layer, layer_query, calculations, resource)
    else
      Enum.reduce_while(calculations, {:ok, layer_query}, fn {calculation, expression},
                                                             {:ok, acc} ->
        case layer.add_calculation(acc, calculation, expression, resource) do
          {:ok, acc} -> {:cont, {:ok, acc}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end
  end

  defp callback?(layer, name, arity) do
    Code.ensure_loaded?(layer) and function_exported?(layer, name, arity)
  end
end
