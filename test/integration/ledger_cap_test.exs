defmodule AshMultiDatalayer.Integration.LedgerCapTest do
  use AshMultiDatalayer.DataCase, async: false

  require Ash.Query

  alias AshMultiDatalayer.Coverage
  alias AshMultiDatalayer.Test.Resources.CappedPost

  setup do
    for {name, age} <- [{"a", 1}, {"b", 2}, {"c", 3}, {"d", 4}, {"e", 5}] do
      MirrorPost
      |> Ash.Changeset.for_create(:create, %{name: name, age: age})
      |> Ash.create!()
    end

    parent = self()
    handler = "ledger-cap-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [[:ash_multi_datalayer, :ledger, :evicted], [:ash_multi_datalayer, :ledger, :full]],
      fn event, measurements, metadata, _ ->
        send(parent, {:mdl, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  defp warm!(name) do
    CappedPost |> Ash.Query.filter(name == ^name) |> Ash.read!()
  end

  test "the cap holds: inserting past it evicts the least-recently-used entry" do
    warm!("a")
    warm!("b")
    warm!("c")
    assert Coverage.size(CappedPost, nil) == 3

    # LRU-touch "a" so "b" is now the least recently used.
    warm!("a")

    # A fourth distinct filter evicts "b".
    warm!("d")
    assert Coverage.size(CappedPost, nil) == 3
    assert_receive {:mdl, [_, :ledger, :evicted], _, %{resource: CappedPost}}

    reads_before = CountingLayer.count(AshMultiDatalayer.Test.CountingPostgres, :run_query)

    # "a" is still covered (was touched), "b" was evicted.
    warm!("a")

    assert CountingLayer.count(AshMultiDatalayer.Test.CountingPostgres, :run_query) ==
             reads_before

    warm!("b")

    assert CountingLayer.count(AshMultiDatalayer.Test.CountingPostgres, :run_query) ==
             reads_before + 1
  end

  test "eviction happens once per over-cap insert" do
    for name <- ~w(a b c d e) do
      warm!(name)
    end

    assert Coverage.size(CappedPost, nil) == 3
    assert_receive {:mdl, [_, :ledger, :evicted], _, _}
    assert_receive {:mdl, [_, :ledger, :evicted], _, _}
    refute_receive {:mdl, [_, :ledger, :evicted], _, _}, 50
  end
end
