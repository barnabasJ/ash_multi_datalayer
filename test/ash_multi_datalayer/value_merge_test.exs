defmodule AshMultiDatalayer.ValueMergeTest do
  use ExUnit.Case, async: true

  import Ash.Expr

  alias AshMultiDatalayer.DataLayer.Query
  alias AshMultiDatalayer.Test.Resources.{LocalEvalOffPost, TestPost}
  alias AshMultiDatalayer.ValueMerge

  defmodule SourceOnly do
    @moduledoc false
    def expression(layer, _args) when layer in [Ash.DataLayer.Ets, Ash.DataLayer.Simple],
      do: :unknown

    def expression(_layer, [name | _]), do: {:ok, name}
  end

  defp qcalc(name), do: %Ash.Query.Calculation{name: name}

  defp source_only_expr do
    custom = %Ash.CustomExpression{module: SourceOnly, arguments: ["cc"], expression: "cc"}
    expr(^custom > 5)
  end

  defp query(resource, calcs), do: %Query{resource: resource, calculations: calcs}

  test "splits cache-evaluable calcs from source-only calcs" do
    local = {qcalc(:adult?), expr(age >= 18)}
    remote = {qcalc(:comment_count), source_only_expr()}

    {locals, sources} =
      ValueMerge.local_and_source_calculations(
        query(TestPost, [local, remote]),
        TestPost,
        Ash.DataLayer.Ets
      )

    assert locals == [local]
    assert sources == [remote]
  end

  test "with local evaluation off, every calc is source-only" do
    local = {qcalc(:adult?), expr(age >= 18)}

    {locals, sources} =
      ValueMerge.local_and_source_calculations(
        query(LocalEvalOffPost, [local]),
        LocalEvalOffPost,
        Ash.DataLayer.Ets
      )

    assert locals == []
    assert sources == [local]
  end
end
