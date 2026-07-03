defmodule AshMultiDatalayer.Integration.MergeReadsTest do
  use AshMultiDatalayer.DataCase, async: false

  require Ash.Query

  alias AshMultiDatalayer.Test.CountingPostgres
  alias AshMultiDatalayer.Test.Resources.TestAuthor

  defp pg_reads, do: CountingLayer.count(CountingPostgres, :run_query)

  setup do
    reset_resource!(TestAuthor)

    parent = self()
    handler = "merge-reads-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [[:ash_multi_datalayer, :read, :hit], [:ash_multi_datalayer, :read, :miss]],
      fn event, measurements, metadata, _ ->
        send(parent, {:mdl, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    author =
      TestAuthor
      |> Ash.Changeset.for_create(:create, %{name: "ada"})
      |> Ash.create!()

    for {name, age} <- [{"kid", 10}, {"grown", 30}] do
      TestPost
      |> Ash.Changeset.for_create(:create, %{name: name, age: age, author_id: author.id})
      |> Ash.create!()
    end

    AshMultiDatalayer.Coverage.reset(TestPost)
    AshMultiDatalayer.Coverage.reset(TestAuthor)
    CountingLayer.reset!()

    {:ok, author: author}
  end

  test "a calculation-loading read over covered rows merges values from the source" do
    # Warm row coverage.
    TestPost |> Ash.Query.filter(age > 0) |> Ash.read!()
    assert pg_reads() == 1

    # Calc-loaded read: rows from cache, ONE value query for adult?.
    posts =
      TestPost
      |> Ash.Query.filter(age > 0)
      |> Ash.Query.load(:adult?)
      |> Ash.read!()
      |> Map.new(&{&1.name, &1.adult?})

    assert posts == %{"kid" => false, "grown" => true}
    assert pg_reads() == 2
    assert_receive {:mdl, [_, :read, :hit], _, %{computed_values: :merged}}

    # Every computed-value read re-fetches values (never cached) - but only
    # values: still one narrow query each.
    TestPost |> Ash.Query.filter(age > 0) |> Ash.Query.load(:adult?) |> Ash.read!()
    assert pg_reads() == 3
  end

  test "relationship aggregates fail loudly instead of silently NotLoaded" do
    # SQL layers build the related subquery via the DESTINATION resource's
    # data layer (this library), which cannot yield SQL - the aggregate
    # would silently come back NotLoaded. can?({:aggregate, _}) is false so
    # this is a loud error at query build.
    assert_raise Ash.Error.Invalid, ~r/aggregate/i, fn ->
      TestAuthor
      |> Ash.Query.filter(name == "ada")
      |> Ash.Query.load(:post_count)
      |> Ash.read!()
    end
  end

  test "a computed-carrying COLD read records row coverage for later plain reads" do
    TestPost
    |> Ash.Query.filter(age > 20)
    |> Ash.Query.load(:adult?)
    |> Ash.read!()

    assert_receive {:mdl, [_, :read, :miss], _, %{reason: :no_coverage_entry}}
    reads = pg_reads()

    # The rows fetched alongside the calc warmed the cache.
    assert [%{name: "grown"}] = TestPost |> Ash.Query.filter(age > 20) |> Ash.read!()
    assert pg_reads() == reads
    assert_receive {:mdl, [_, :read, :hit], _, _}
  end

  test "merged values equal a cache-disabled read's values" do
    query = TestPost |> Ash.Query.filter(age > 0) |> Ash.Query.load(:adult?)

    # Warm, then merged read.
    Ash.read!(TestPost)
    merged = query |> Ash.read!() |> Enum.map(&{&1.id, &1.adult?}) |> Enum.sort()

    AshMultiDatalayer.disable!(TestPost)

    try do
      direct = query |> Ash.read!() |> Enum.map(&{&1.id, &1.adult?}) |> Enum.sort()
      assert merged == direct
    after
      AshMultiDatalayer.enable!(TestPost)
    end
  end

  test "an out-of-band delete abandons the merge and serves everything fresh" do
    TestPost |> Ash.Query.filter(age > 0) |> Ash.read!()

    # Delete a row straight through Postgres (MirrorPost) - the cache and
    # ledger never hear about it.
    MirrorPost |> Ash.Query.filter(name == "kid") |> Ash.read!() |> hd() |> Ash.destroy!()

    # The merged read notices the cached row has no source counterpart and
    # falls through whole: fresh rows, fresh values, no half-merged result.
    posts =
      TestPost
      |> Ash.Query.filter(age > 0)
      |> Ash.Query.load(:adult?)
      |> Ash.read!()

    assert [%{name: "grown", adult?: true}] = posts
    assert_receive {:mdl, [_, :read, :miss], _, %{reason: :stale_cache}}
  end

  test "limited computed reads are served from coverage with a narrow value query" do
    TestPost |> Ash.Query.filter(age > 0) |> Ash.read!()
    reads = pg_reads()

    [post] =
      TestPost
      |> Ash.Query.filter(age > 0)
      |> Ash.Query.sort(:age)
      |> Ash.Query.limit(1)
      |> Ash.Query.load(:adult?)
      |> Ash.read!()

    assert %{name: "kid", adult?: false} = post
    assert pg_reads() == reads + 1
  end
end
