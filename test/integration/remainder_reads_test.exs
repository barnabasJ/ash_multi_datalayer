defmodule AshMultiDatalayer.Integration.RemainderReadsTest do
  use AshMultiDatalayer.DataCase, async: false

  require Ash.Query

  alias AshMultiDatalayer.Test.CountingPostgres

  defp pg_reads, do: CountingLayer.count(CountingPostgres, :run_query)

  setup do
    parent = self()
    handler = "remainder-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [
        [:ash_multi_datalayer, :read, :hit],
        [:ash_multi_datalayer, :read, :miss],
        [:ash_multi_datalayer, :read, :partial]
      ],
      fn event, measurements, metadata, _ ->
        send(parent, {:mdl, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    for {name, age} <- [{"low", 3}, {"mid", 5}, {"high", 30}] do
      TestPost |> Ash.Changeset.for_create(:create, %{name: name, age: age}) |> Ash.create!()
    end

    # A nil-attribute row: the flagship case — it must survive the complement.
    TestPost |> Ash.Changeset.for_create(:create, %{name: "nilage", age: nil}) |> Ash.create!()

    AshMultiDatalayer.Coverage.reset(TestPost)
    CountingLayer.reset!()
    :ok
  end

  test "a partially-covered read fetches only the remainder, including the nil-age row" do
    # Warm coverage for age > 5 (only "high").
    assert ["high"] = TestPost |> Ash.Query.filter(age > 5) |> Ash.read!() |> Enum.map(& &1.name)
    reads = pg_reads()

    # Read everything: "high" comes from the cache, the rest — age <= 5 OR
    # is_nil(age) — from the source in ONE remainder query.
    all = TestPost |> Ash.read!() |> Enum.map(& &1.name) |> Enum.sort()
    assert all == ["high", "low", "mid", "nilage"]
    assert pg_reads() == reads + 1
    assert_receive {:mdl, [_, :read, :partial], _, %{cached: 1, fetched: 3}}

    # The remainder backfilled + recorded Q: the next identical read is a full hit.
    TestPost |> Ash.read!()
    assert pg_reads() == reads + 1
    assert_receive {:mdl, [_, :read, :hit], _, _}
  end

  test "a remainder read composes with the query's own filter" do
    # Warm coverage for age > 5.
    TestPost |> Ash.Query.filter(age > 5) |> Ash.read!()
    reads = pg_reads()

    # Q = age >= 3: "high" covered (from cache), "low"/"mid" the remainder
    # (from source); "nilage" matches neither Q side and is excluded.
    names =
      TestPost |> Ash.Query.filter(age >= 3) |> Ash.read!() |> Enum.map(& &1.name) |> Enum.sort()

    assert names == ["high", "low", "mid"]
    assert pg_reads() == reads + 1
    assert_receive {:mdl, [_, :read, :partial], _, _}
  end

  test "the remainder equals a cache-disabled read" do
    TestPost |> Ash.Query.filter(age > 5) |> Ash.read!()

    remainder = TestPost |> Ash.read!() |> Enum.map(& &1.id) |> Enum.sort()

    AshMultiDatalayer.disable!(TestPost)

    try do
      direct = TestPost |> Ash.read!() |> Enum.map(& &1.id) |> Enum.sort()
      assert remainder == direct
    after
      AshMultiDatalayer.enable!(TestPost)
    end
  end
end
