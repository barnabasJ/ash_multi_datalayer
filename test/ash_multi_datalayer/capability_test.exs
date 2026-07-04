defmodule AshMultiDatalayer.CapabilityTest do
  use ExUnit.Case, async: true

  import Ash.Expr

  alias AshMultiDatalayer.Capability
  alias AshMultiDatalayer.Test.Resources.TestPost

  # A stand-in for ash_remote's `remote(...)`: resolvable on a real source
  # layer, `:unknown` on the in-VM layers — the exact per-layer advertisement
  # the probe keys on.
  defmodule SourceOnly do
    @moduledoc false
    def expression(layer, _arguments) when layer in [Ash.DataLayer.Ets, Ash.DataLayer.Simple],
      do: :unknown

    def expression(_layer, [name | _]), do: {:ok, name}
  end

  defp source_only(name) do
    %Ash.CustomExpression{module: SourceOnly, arguments: [name], expression: name}
  end

  describe "custom_expressions/1" do
    test "finds none in a plain expression" do
      assert Capability.custom_expressions(expr(age >= 18)) == []
    end

    test "finds a custom expression nested inside operators and lists" do
      custom = source_only("comment_count")
      expr = expr(^custom > 5 and not is_nil(id))

      assert [%Ash.CustomExpression{module: SourceOnly}] = Capability.custom_expressions(expr)
    end
  end

  describe "layer_can_evaluate?/3" do
    test "a plain expression is evaluable by the in-VM cache layer" do
      assert Capability.layer_can_evaluate?(Ash.DataLayer.Ets, TestPost, expr(age >= 18))
    end

    test "a source-only custom expression is NOT evaluable by the cache layer" do
      expr = expr(^source_only("comment_count") > 5)
      refute Capability.layer_can_evaluate?(Ash.DataLayer.Ets, TestPost, expr)
    end

    test "a source-only custom expression IS evaluable by the source layer" do
      expr = expr(^source_only("comment_count") > 5)

      assert Capability.layer_can_evaluate?(
               AshMultiDatalayer.Test.CountingPostgres,
               TestPost,
               expr
             )
    end
  end
end
