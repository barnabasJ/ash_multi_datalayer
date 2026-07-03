defmodule AshMultiDatalayer.Coverage.InvalidationTest do
  use ExUnit.Case, async: true

  alias AshMultiDatalayer.Coverage.{Entry, Invalidation, Normaliser}
  alias AshMultiDatalayer.Test.Resources.TestPost

  defp entry(statement) do
    filter = statement && Ash.Filter.parse!(TestPost, statement)

    %Entry{
      id: make_ref(),
      tenant: :__global__,
      filter: filter,
      normalised: filter && Normaliser.normalise(filter, TestPost),
      loaded_fields: MapSet.new([:id, :name, :age]),
      loaded_at: System.monotonic_time()
    }
  end

  defp row(attrs), do: struct(TestPost, attrs)

  test "drops when the filter matches row_after (create)" do
    assert Invalidation.should_drop?(entry(name: [eq: "foo"]), nil, row(name: "foo"))
    refute Invalidation.should_drop?(entry(name: [eq: "foo"]), nil, row(name: "bar"))
  end

  test "drops when the filter matches row_before (destroy)" do
    assert Invalidation.should_drop?(entry(name: [eq: "foo"]), row(name: "foo"), nil)
    refute Invalidation.should_drop?(entry(name: [eq: "foo"]), row(name: "bar"), nil)
  end

  test "drops when either side matches (update moving in or out)" do
    e = entry(age: [greater_than: 30])
    assert Invalidation.should_drop?(e, row(age: 40), row(age: 20))
    assert Invalidation.should_drop?(e, row(age: 20), row(age: 40))
    refute Invalidation.should_drop?(e, row(age: 10), row(age: 20))
  end

  test "nil rows on both sides never drop" do
    refute Invalidation.should_drop?(entry(name: [eq: "foo"]), nil, nil)
  end

  test "universal coverage (no filter) is dropped by any row change" do
    assert Invalidation.should_drop?(entry(nil), nil, row(name: "x"))
    assert Invalidation.should_drop?(entry(nil), row(name: "x"), nil)
    refute Invalidation.should_drop?(entry(nil), nil, nil)
  end

  test "runtime-evaluatable non-interval filters still invalidate precisely" do
    # `contains` is opaque to the SOLVER but perfectly evaluatable by the
    # runtime matcher — invalidation stays row-aware for it.
    e = entry(name: [contains: "oo"])
    assert Invalidation.should_drop?(e, nil, row(name: "foo"))
    refute Invalidation.should_drop?(e, nil, row(name: "bar"))
    # A nil operand is a KNOWN non-match at runtime.
    refute Invalidation.should_drop?(e, nil, row(name: nil))
  end

  test "unknown or crashing evaluations drop conservatively" do
    # A filter whose expression the evaluator cannot process at all.
    broken = %Entry{
      id: make_ref(),
      tenant: :__global__,
      filter: %Ash.Filter{resource: TestPost, expression: {:garbage, :expression}},
      normalised: nil,
      loaded_fields: MapSet.new([:id]),
      loaded_at: 0
    }

    assert Invalidation.should_drop?(broken, nil, row(name: "foo"))
  end
end
