defmodule AshMultiDatalayer.Integration.BulkOperationsTest do
  use AshMultiDatalayer.DataCase, async: false

  require Ash.Query

  test "bulk updates route through the write dispatcher (per-record fallback)" do
    for {name, age} <- [{"a", 1}, {"b", 2}] do
      TestPost
      |> Ash.Changeset.for_create(:create, %{name: name, age: age})
      |> Ash.create!()
    end

    # Warm coverage.
    TestPost |> Ash.Query.filter(age > 0) |> Ash.read!()
    warm_reads = CountingLayer.count(AshMultiDatalayer.Test.CountingPostgres, :run_query)

    # Bulk update: with update_query/atomics disabled, Ash streams records
    # and updates each through our update/2 — invalidation must fire.
    %Ash.BulkResult{error_count: 0} =
      TestPost
      |> Ash.Query.filter(age > 0)
      |> Ash.bulk_update!(:update, %{age: 100}, strategy: [:stream])

    # Coverage was invalidated by the per-record writes: fresh fall-through.
    rows = TestPost |> Ash.Query.filter(age > 0) |> Ash.read!()
    assert Enum.map(rows, & &1.age) == [100, 100]

    assert CountingLayer.count(AshMultiDatalayer.Test.CountingPostgres, :run_query) >
             warm_reads
  end

  test "bulk destroys route through the write dispatcher" do
    record =
      TestPost
      |> Ash.Changeset.for_create(:create, %{name: "bulk-gone", age: 1})
      |> Ash.create!()

    TestPost |> Ash.Query.filter(name == "bulk-gone") |> Ash.read!()

    %Ash.BulkResult{error_count: 0} =
      TestPost
      |> Ash.Query.filter(id == ^record.id)
      |> Ash.bulk_destroy!(:destroy, %{}, strategy: [:stream])

    assert [] = TestPost |> Ash.Query.filter(name == "bulk-gone") |> Ash.read!()
  end
end
