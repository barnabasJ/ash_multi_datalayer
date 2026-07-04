defmodule AshMultiDatalayer.Integration.MergeReadsTest do
  use AshMultiDatalayer.DataCase, async: false

  require Ash.Query

  alias AshMultiDatalayer.Test.CountingPostgres
  alias AshMultiDatalayer.Test.Resources.{LocalEvalOffPost, TestAuthor}

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

  # --- local evaluation (default): the cache layer computes the calc ---------

  test "a mirrored calc over covered rows is computed locally, with no source read" do
    # Warm row coverage.
    TestPost |> Ash.Query.filter(age > 0) |> Ash.read!()
    assert pg_reads() == 1

    posts =
      TestPost
      |> Ash.Query.filter(age > 0)
      |> Ash.Query.load(:adult?)
      |> Ash.read!()
      |> Map.new(&{&1.name, &1.adult?})

    assert posts == %{"kid" => false, "grown" => true}
    # No extra source read — the cache layer evaluated `adult?` from its rows.
    assert pg_reads() == 1
    assert_receive {:mdl, [_, :read, :hit], _, %{computed_values: :local}}
  end

  test "local values equal a cache-disabled read's values" do
    query = TestPost |> Ash.Query.filter(age > 0) |> Ash.Query.load(:adult?)

    Ash.read!(TestPost)
    local = query |> Ash.read!() |> Enum.map(&{&1.id, &1.adult?}) |> Enum.sort()

    AshMultiDatalayer.disable!(TestPost)

    try do
      direct = query |> Ash.read!() |> Enum.map(&{&1.id, &1.adult?}) |> Enum.sort()
      assert local == direct
    after
      AshMultiDatalayer.enable!(TestPost)
    end
  end

  test "a limited local-calc read is served from coverage with no source read" do
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
    assert pg_reads() == reads
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

  # --- local evaluation off (override): fetched from the source --------------

  test "with local evaluation off, a calc is fetched from the source in one narrow query" do
    # LocalEvalOffPost shares mdl_posts (already seeded) but has its own cache.
    LocalEvalOffPost |> Ash.Query.filter(age > 0) |> Ash.read!()
    reads = pg_reads()

    posts =
      LocalEvalOffPost
      |> Ash.Query.filter(age > 0)
      |> Ash.Query.load(:adult?)
      |> Ash.read!()
      |> Map.new(&{&1.name, &1.adult?})

    assert posts == %{"kid" => false, "grown" => true}
    assert pg_reads() == reads + 1
    assert_receive {:mdl, [_, :read, :hit], _, %{computed_values: :merged}}
  end

  test "with local evaluation off, an out-of-band delete abandons the merge" do
    LocalEvalOffPost |> Ash.Query.filter(age > 0) |> Ash.read!()

    # Delete a row straight through Postgres (MirrorPost) - the cache and
    # ledger never hear about it.
    MirrorPost |> Ash.Query.filter(name == "kid") |> Ash.read!() |> hd() |> Ash.destroy!()

    # The source value query notices the cached row has no counterpart and the
    # read falls through whole: fresh rows, fresh values, no half-merged result.
    posts =
      LocalEvalOffPost
      |> Ash.Query.filter(age > 0)
      |> Ash.Query.load(:adult?)
      |> Ash.read!()

    assert [%{name: "grown", adult?: true}] = posts
    assert_receive {:mdl, [_, :read, :miss], _, %{reason: :stale_cache}}
  end

  # --- relationship aggregates: folded from the related rows -------------------

  test "a relationship aggregate over covered related rows is folded with no source read" do
    # Warm both the author row and the related-row coverage: every post is now
    # cached (universe coverage subsumes the fold's `author_id == …` read), and
    # so is the author itself.
    TestAuthor |> Ash.read!()
    TestPost |> Ash.read!()
    reads = pg_reads()

    author =
      TestAuthor
      |> Ash.Query.filter(name == "ada")
      |> Ash.Query.load([:post_count, :adult_post_count])
      |> Ash.read_one!()

    assert author.post_count == 2
    # The filtered aggregate is folded in memory (only "grown", age 30, is >= 18).
    assert author.adult_post_count == 1
    # The count came from the cache — no round trip to Postgres for the related rows.
    assert pg_reads() == reads
  end

  test "a folded aggregate equals an independent count of the actual related rows", %{
    author: author
  } do
    # A cache-disabled read cannot be the oracle here: with MDL off, the
    # aggregate is handed straight to Postgres, which cannot compute a count
    # over the MDL-wrapped `TestPost` (the cross-layer limitation) — the fold is
    # the only thing that produces this value. So verify against the real rows.
    posts = TestPost |> Ash.Query.filter(author_id == ^author.id) |> Ash.read!()
    expected_total = length(posts)
    expected_adult = Enum.count(posts, &(&1.age >= 18))

    folded =
      TestAuthor
      |> Ash.Query.filter(name == "ada")
      |> Ash.Query.load([:post_count, :adult_post_count])
      |> Ash.read_one!()

    assert folded.post_count == expected_total
    assert folded.adult_post_count == expected_adult
  end

  test "a cold relationship aggregate folds correctly by fetching the related rows" do
    # No warming: the related rows aren't covered yet. The fold loads them
    # through the read path (a source read), backfills, and counts — still
    # correct, and warms the cache for next time.
    author =
      TestAuthor
      |> Ash.Query.filter(name == "ada")
      |> Ash.Query.load(:post_count)
      |> Ash.read_one!()

    assert author.post_count == 2

    reads = pg_reads()

    # The related rows the fold fetched are now cached — a second fold is free.
    again =
      TestAuthor
      |> Ash.Query.filter(name == "ada")
      |> Ash.Query.load(:post_count)
      |> Ash.read_one!()

    assert again.post_count == 2
    assert pg_reads() == reads
  end
end
