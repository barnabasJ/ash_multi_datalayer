defmodule AshMultiDatalayer.Capability do
  @moduledoc """
  Probes whether an underlying read layer can *evaluate* an expression — the
  per-layer signal the router uses to decide where a calculation's value is
  computed (local-eval routing) and whether a calc-referencing filter or sort
  may be served from an earlier layer (calc routing).

  A layer can evaluate an expression when it supports expression calculations
  at all **and** every `Ash.CustomExpression` embedded in it can be evaluated
  in-VM — its `simple_expression` is not `:unknown`. Ash hydrates a custom
  expression to `{expression, simple_expression}` (the latter is what the
  in-VM runtime, `Ash.Filter.Runtime`, evaluates — the same engine the cache
  layer uses); a `:unknown` there is exactly how `ash_remote`'s `remote(...)`
  reports "I have no client-side value — send me to the source". (The struct's
  `:module` is *not* retained through hydration, so `simple_expression`, not
  the module, is the signal.) This is the cache-layer question the router asks;
  it is not called for source layers.

  This is fully data-layer agnostic: MDL asks the layer and the expression,
  and encodes no per-function or per-layer knowledge of its own. Ensuring two
  layers that both claim to support an expression return the same value is the
  operator's responsibility (see the merge-reads ADR's layer-consistency
  contract), not a rule enforced here.
  """

  @doc """
  Whether `layer` can evaluate `expression` for `resource`.

  Returns `false` for a layer that does not support expression calculations,
  or when any custom expression in the tree is `:unknown` on that layer.
  """
  @spec layer_can_evaluate?(module(), Ash.Resource.t(), term()) :: boolean()
  def layer_can_evaluate?(layer, resource, expression) do
    Ash.DataLayer.can?(layer, resource, :expression_calculation) and
      Enum.all?(custom_expressions(expression), &in_vm_evaluable?/1)
  end

  defp in_vm_evaluable?(%Ash.CustomExpression{simple_expression: {:ok, _}}), do: true
  defp in_vm_evaluable?(%Ash.CustomExpression{}), do: false

  @doc """
  Every `Ash.CustomExpression` node embedded in `expression`.

  Ash's own `Ash.Filter.map/2` and `flat_map/2` recurse *through* a custom
  expression without ever handing the node itself to the callback, so this
  walks the tree generically: it descends into lists, tuples, and the values
  of any struct or map, capturing custom-expression nodes as it passes them.
  Being exhaustive here is a correctness requirement — a missed custom
  expression would let the router treat a source-only calc as locally
  evaluable and compute a wrong value from the cache.
  """
  @spec custom_expressions(term()) :: [struct()]
  def custom_expressions(expression), do: collect(expression, [])

  defp collect(%Ash.CustomExpression{} = custom, acc),
    do: collect(custom.expression, [custom | acc])

  defp collect(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect/2)

  defp collect(tuple, acc) when is_tuple(tuple),
    do: collect(Tuple.to_list(tuple), acc)

  defp collect(%_struct{} = node, acc),
    do: node |> Map.from_struct() |> Map.values() |> collect(acc)

  defp collect(map, acc) when is_map(map),
    do: map |> Map.values() |> collect(acc)

  defp collect(_leaf, acc), do: acc
end
