defmodule AshMultiDatalayer.DebugTest do
  use AshMultiDatalayer.DataCase, async: false

  require Ash.Query

  alias AshMultiDatalayer.Debug

  test "dump_ledger and explain_covers? trace the coverage decision" do
    TestPost
    |> Ash.Changeset.for_create(:create, %{name: "foo", age: 20})
    |> Ash.create!()

    AshMultiDatalayer.Coverage.reset(TestPost)

    # Warm one filter.
    TestPost |> Ash.Query.filter(name == "foo") |> Ash.read!()

    assert [entry] = Debug.dump_ledger(TestPost)
    assert entry.filter

    # A narrower probe: hit, with the trace naming the covering entry.
    {decision, trace} =
      Debug.explain_covers?(
        TestPost,
        TestPost |> Ash.Query.filter(name == "foo" and age > 18)
      )

    assert {:hit, ^entry} = decision
    assert [%{verdict: :covers}] = trace

    # A disjoint probe: miss with :not_implied on the entry.
    {decision, trace} =
      Debug.explain_covers?(TestPost, Ash.Query.filter(TestPost, name == "bar"))

    assert {:miss, :no_coverage_entry} = decision
    assert [%{verdict: :not_implied}] = trace

    # An unsupported probe: solver_unsupported.
    {decision, _trace} =
      Debug.explain_covers?(TestPost, Ash.Query.filter(TestPost, contains(name, "f")))

    assert {:miss, :solver_unsupported} = decision
  end

  test "TestSupport.reset! clears ledger, cache, and kill-switch" do
    TestPost
    |> Ash.Changeset.for_create(:create, %{name: "foo", age: 20})
    |> Ash.create!()

    TestPost |> Ash.Query.filter(name == "foo") |> Ash.read!()
    AshMultiDatalayer.disable!(TestPost)

    assert AshMultiDatalayer.Coverage.size(TestPost, nil) >= 0
    :ok = AshMultiDatalayer.TestSupport.reset!(TestPost)

    assert Debug.dump_ledger(TestPost) == []
    assert AshMultiDatalayer.enabled?(TestPost)
  end
end
