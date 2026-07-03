defmodule AshMultiDatalayer.Integration.DropInReplacementTest do
  use AshMultiDatalayer.DataCase, async: false

  require Ash.Query

  defp seed!(attrs) do
    MirrorPost
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!()
  end

  setup do
    seed!(%{name: "alpha", age: 20, published_at: ~D[2026-01-15]})
    seed!(%{name: "beta", age: 35, published_at: ~D[2026-03-01]})
    seed!(%{name: "gamma", age: 50})
    :ok
  end

  test "single-layer read_order reads exactly like plain AshPostgres" do
    expected =
      MirrorPost
      |> Ash.Query.filter(age > 25)
      |> Ash.Query.sort(:name)
      |> Ash.read!()

    actual =
      SingleLayerPost
      |> Ash.Query.filter(age > 25)
      |> Ash.Query.sort(:name)
      |> Ash.read!()

    assert Enum.map(actual, &{&1.id, &1.name, &1.age}) ==
             Enum.map(expected, &{&1.id, &1.name, &1.age})

    # The read went through the counted Postgres layer.
    assert CountingLayer.count(AshMultiDatalayer.Test.CountingPostgres, :run_query) >= 1
  end

  test "limit/offset/sort are pushed to the layer" do
    names =
      SingleLayerPost
      |> Ash.Query.sort(:age)
      |> Ash.Query.limit(2)
      |> Ash.Query.offset(1)
      |> Ash.read!()
      |> Enum.map(& &1.name)

    assert names == ["beta", "gamma"]
  end

  test "multi-layer read_order without coverage behaves like the source of truth" do
    result =
      TestPost
      |> Ash.Query.filter(name == "alpha")
      |> Ash.read!()

    assert [%{name: "alpha", age: 20}] = result
    assert CountingLayer.count(AshMultiDatalayer.Test.CountingPostgres, :run_query) == 1
  end

  test "kill-switch routes reads to the last read layer" do
    AshMultiDatalayer.disable!(TestPost)

    assert [_, _, _] = Ash.read!(TestPost)
    assert CountingLayer.count(AshMultiDatalayer.Test.CountingPostgres, :run_query) == 1
  after
    AshMultiDatalayer.enable!(TestPost)
  end

  test "get-by-id works through the multi datalayer" do
    %{id: id} = seed!(%{name: "delta", age: 61})

    assert %{name: "delta"} = Ash.get!(TestPost, id)
  end
end
