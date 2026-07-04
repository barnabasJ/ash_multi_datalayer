defmodule AshMultiDatalayer.CapabilityTest do
  use ExUnit.Case, async: true

  import Ash.Expr

  alias AshMultiDatalayer.Capability
  alias AshMultiDatalayer.Test.Resources.TestPost

  # A stand-in for ash_remote's `remote(...)`: no in-VM value, so the cache
  # layer can't compute it — exactly what a `:unknown` simple_expression means.
  defp source_only(name),
    do: %Ash.CustomExpression{arguments: [name], expression: name, simple_expression: :unknown}

  # A custom expression the in-VM runtime can evaluate.
  defp evaluable(name),
    do: %Ash.CustomExpression{arguments: [name], expression: 1, simple_expression: {:ok, 1}}

  describe "custom_expressions/1" do
    test "finds none in a plain expression" do
      assert Capability.custom_expressions(expr(age >= 18)) == []
    end

    test "finds a custom expression nested inside operators" do
      custom = source_only("comment_count")
      expression = expr(^custom > 5 and not is_nil(id))

      assert [%Ash.CustomExpression{simple_expression: :unknown}] =
               Capability.custom_expressions(expression)
    end
  end

  describe "layer_can_evaluate?/3" do
    test "a plain expression is evaluable by the in-VM cache layer" do
      assert Capability.layer_can_evaluate?(Ash.DataLayer.Ets, TestPost, expr(age >= 18))
    end

    test "a custom expression with an in-VM simple_expression is evaluable" do
      expression = expr(^evaluable("x") > 5)
      assert Capability.layer_can_evaluate?(Ash.DataLayer.Ets, TestPost, expression)
    end

    test "a source-only custom expression (:unknown) is NOT evaluable by the cache layer" do
      expression = expr(^source_only("comment_count") > 5)
      refute Capability.layer_can_evaluate?(Ash.DataLayer.Ets, TestPost, expression)
    end
  end
end
