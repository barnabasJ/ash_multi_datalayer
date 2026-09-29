defmodule AshMultiDatalayer.Integration.RowAwareInvalidationTest do
  use AshMultiDatalayer.DataCase, async: false

  require Ash.Query

  alias AshMultiDatalayer.Test.CountingPostgres

  defp pg_reads, do: CountingLayer.count(CountingPostgres, :run_query)

  defp warm!(query) do
    Ash.read!(query)
  end

  setup do
    foo =
      TestPost
      |> Ash.Changeset.for_create(:create, %{name: "foo", age: 20})
      |> Ash.create!()

    bar =
      TestPost
      |> Ash.Changeset.for_create(:create, %{name: "bar", age: 40})
      |> Ash.create!()

    # Writes above may have invalidated coverage; start each test from a
    # clean, warm slate.
    AshMultiDatalayer.Coverage.reset(TestPost)
    CountingLayer.reset!()

    {:ok, foo: foo, bar: bar}
  end

  test "an update drops only coverage matching the changed row", %{foo: foo} do
    warm!(Ash.Query.filter(TestPost, name == "foo"))
    warm!(Ash.Query.filter(TestPost, name == "bar"))
    assert pg_reads() == 2

    foo
    |> Ash.Changeset.for_update(:update, %{age: 21})
    |> Ash.update!()

    # foo coverage dropped -> next read falls through and re-warms.
    assert [%{age: 21}] = warm!(Ash.Query.filter(TestPost, name == "foo"))
    assert pg_reads() == 3

    # bar coverage untouched -> still a hit.
    assert [%{name: "bar"}] = warm!(Ash.Query.filter(TestPost, name == "bar"))
    assert pg_reads() == 3
  end

  test "one changed row stays a hole in one ledger entry and only that row is fetched", %{
    foo: foo
  } do
    handler = "row-hole-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler,
      [:ash_multi_datalayer, :read, :partial],
      fn event, _, metadata, _ ->
        send(parent, {event, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert length(Ash.read!(TestPost)) == 2
    assert pg_reads() == 1
    assert length(AshMultiDatalayer.Coverage.entries(TestPost, nil)) == 1

    foo
    |> Ash.Changeset.for_update(:update, %{age: 21})
    |> Ash.update!()

    [entry] = AshMultiDatalayer.Coverage.entries(TestPost, nil)
    assert entry.excluded_ids == [foo.id]

    assert Ash.read!(TestPost) |> Enum.map(& &1.age) |> Enum.sort() == [21, 40]
    assert_receive {[:ash_multi_datalayer, :read, :partial], %{cached: 1, fetched: 1}}
    assert pg_reads() == 2

    [healed] = AshMultiDatalayer.Coverage.entries(TestPost, nil)
    assert healed.excluded_ids == []
    assert length(Ash.read!(TestPost)) == 2
    assert pg_reads() == 2
  end

  test "two changed rows remain exclusions in the same ledger entry", %{foo: foo, bar: bar} do
    Ash.read!(TestPost)

    foo |> Ash.Changeset.for_update(:update, %{age: 21}) |> Ash.update!()
    bar |> Ash.Changeset.for_update(:update, %{age: 41}) |> Ash.update!()

    [entry] = AshMultiDatalayer.Coverage.entries(TestPost, nil)
    assert MapSet.new(entry.excluded_ids) == MapSet.new([foo.id, bar.id])

    assert TestPost |> Ash.read!() |> Enum.map(& &1.age) |> Enum.sort() == [21, 41]
    assert pg_reads() == 2
    assert [%{excluded_ids: []}] = AshMultiDatalayer.Coverage.entries(TestPost, nil)
  end

  test "a row moving INTO a cached filter drops that filter's coverage", %{foo: foo} do
    warm!(Ash.Query.filter(TestPost, age > 30))
    assert pg_reads() == 1

    # foo (age 20) doesn't match the cached filter before the update, but
    # does after: row_after matching must drop the entry.
    foo
    |> Ash.Changeset.for_update(:update, %{age: 35})
    |> Ash.update!()

    result = warm!(Ash.Query.filter(TestPost, age > 30))
    assert pg_reads() == 2
    assert Enum.any?(result, &(&1.id == foo.id))
  end

  test "creates drop matching coverage and leave unrelated coverage warm" do
    warm!(Ash.Query.filter(TestPost, name == "baz"))
    warm!(Ash.Query.filter(TestPost, name == "bar"))
    assert pg_reads() == 2

    TestPost
    |> Ash.Changeset.for_create(:create, %{name: "baz", age: 1})
    |> Ash.create!()

    # The new row matches name == "baz": that coverage is gone and the next
    # read includes the new row.
    assert [%{name: "baz"}] = warm!(Ash.Query.filter(TestPost, name == "baz"))
    assert pg_reads() == 3

    assert [%{name: "bar"}] = warm!(Ash.Query.filter(TestPost, name == "bar"))
    assert pg_reads() == 3
  end

  test "destroys drop matching coverage", %{foo: foo} do
    warm!(Ash.Query.filter(TestPost, name == "foo"))
    warm!(Ash.Query.filter(TestPost, name == "bar"))
    assert pg_reads() == 2

    Ash.destroy!(foo)

    assert [] = warm!(Ash.Query.filter(TestPost, name == "foo"))
    assert pg_reads() == 3

    assert [_] = warm!(Ash.Query.filter(TestPost, name == "bar"))
    assert pg_reads() == 3
  end

  test "universal (unfiltered) coverage is dropped by any write" do
    warm!(TestPost)
    assert pg_reads() == 1

    # Served from cache.
    warm!(Ash.Query.filter(TestPost, age > 0))
    assert pg_reads() == 1

    TestPost
    |> Ash.Changeset.for_create(:create, %{name: "new", age: 7})
    |> Ash.create!()

    rows = warm!(TestPost)
    assert pg_reads() == 2
    assert Enum.any?(rows, &(&1.name == "new"))
  end

  test "written records are propagated into the cache from the RETURNED record", %{foo: foo} do
    # Warm broad coverage, then update: coverage matching foo drops, but the
    # cache row itself was upserted with the authoritative layer's values —
    # re-warming and hitting shows them.
    warm!(Ash.Query.filter(TestPost, name == "foo"))

    foo
    |> Ash.Changeset.for_update(:update, %{age: 99})
    |> Ash.update!()

    # Miss + re-warm.
    assert [%{age: 99}] = warm!(Ash.Query.filter(TestPost, name == "foo"))
    reads = pg_reads()

    # Hit: values from cache equal the authoritative row.
    assert [%{age: 99}] = warm!(Ash.Query.filter(TestPost, name == "foo"))
    assert pg_reads() == reads
  end
end
