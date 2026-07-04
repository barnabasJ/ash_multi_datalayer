defmodule AshMultiDatalayer.Coverage.NormaliserTest do
  use ExUnit.Case, async: true

  require Ash.Query

  alias AshMultiDatalayer.Coverage.Normaliser
  alias AshMultiDatalayer.Test.Resources.TestPost

  defp normalise(query), do: Normaliser.normalise(query.filter, TestPost)

  test "a filter on a real attribute normalises to intervals (not opaque)" do
    refute normalise(Ash.Query.filter(TestPost, age >= 18)).opaque?
  end

  test "a filter referencing a calculation is opaque (routes to the source, never a false hit)" do
    # `adult?` is a calc, not an attribute — its ref carries :name/:type but must
    # not be keyed as a plain attribute, or the prover could report a coverage
    # hit and evaluate the calc on a layer that can't compute it.
    assert normalise(Ash.Query.filter(TestPost, adult? == true)).opaque?
  end

  test "a calc predicate conjoined with a real attribute makes the whole filter opaque" do
    assert normalise(Ash.Query.filter(TestPost, age >= 18 and adult? == true)).opaque?
  end
end
