defmodule AshMultiDatalayer.Coverage.ComplementTest do
  use ExUnit.Case, async: true

  require Ash.Query

  alias AshMultiDatalayer.Coverage.{Complement, Normaliser}
  alias AshMultiDatalayer.Test.Generators
  alias AshMultiDatalayer.Test.Resources.TestPost

  defp disjuncts(query), do: Normaliser.normalise(query.filter, TestPost).disjuncts

  test "an empty region covers nothing and its complement is the universe" do
    assert Complement.coverage_filter([], TestPost) == :empty
    assert Complement.complement_filter([], TestPost) == :universe
  end

  test "an unconstrained region is the universe and its complement is empty" do
    assert Complement.coverage_filter([%{}], TestPost) == :universe
    assert Complement.complement_filter([%{}], TestPost) == :empty
  end

  test "the complement of `age > 5` keeps nil-age rows (positive is_nil hatch)" do
    d = disjuncts(Ash.Query.filter(TestPost, age > 5))
    {:ok, complement} = Complement.complement_filter(d, TestPost)

    assert Generators.matches?(struct(TestPost, age: 3), complement) == {:ok, true}
    assert Generators.matches?(struct(TestPost, age: nil), complement) == {:ok, true}
    assert Generators.matches?(struct(TestPost, age: 30), complement) == {:ok, false}
  end
end
