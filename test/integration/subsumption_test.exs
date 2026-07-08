defmodule AshMultiDatalayer.Integration.SubsumptionTest do
  use AshMultiDatalayer.DataCase, async: false

  require Ash.Query

  alias AshMultiDatalayer.Test.CountingPostgres

  defp seed!(attrs) do
    MirrorPost
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!()
  end

  defp pg_reads, do: CountingLayer.count(CountingPostgres, :run_query)

  setup do
    seed!(%{name: "foo", age: 20, published_at: ~D[2026-01-15]})
    seed!(%{name: "foo", age: 15, published_at: ~D[2026-03-01]})
    seed!(%{name: "bar", age: 40, published_at: ~D[2026-06-30]})

    telemetry_ref = make_ref()
    parent = self()

    :telemetry.attach_many(
      "subsumption-test-#{inspect(telemetry_ref)}",
      [
        [:ash_multi_datalayer, :read, :hit],
        [:ash_multi_datalayer, :read, :miss],
        [:ash_multi_datalayer, :read, :backfill]
      ],
      fn event, measurements, metadata, _config ->
        send(parent, {:mdl, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("subsumption-test-#{inspect(telemetry_ref)}") end)
    :ok
  end

  test "the flagship case: a narrower filter is served entirely from the cache" do
    # Cold read: miss + fall-through + backfill.
    assert [_, _] =
             TestPost
             |> Ash.Query.filter(name == "foo")
             |> Ash.read!()

    assert pg_reads() == 1
    assert_receive {:mdl, [_, :read, :miss], _, %{reason: :no_coverage_entry}}
    assert_receive {:mdl, [_, :read, :backfill], _, _}

    # Narrower query: provably contained -> served by ETS, zero Postgres.
    assert [%{name: "foo", age: 20}] =
             TestPost
             |> Ash.Query.filter(name == "foo" and age > 18)
             |> Ash.read!()

    assert pg_reads() == 1
    assert_receive {:mdl, [_, :read, :hit], %{duration_us: _, ledger_size: 1}, _}
  end

  test "identical repeat reads hit the cache" do
    query = Ash.Query.filter(TestPost, age > 18)

    first = Ash.read!(query)
    assert pg_reads() == 1

    second = Ash.read!(query)
    assert pg_reads() == 1
    assert_receive {:mdl, [_, :read, :hit], _, _}

    # Compare attribute data; __meta__ provenance legitimately differs
    # between the Postgres-served and ETS-served reads.
    fields = &{&1.id, &1.name, &1.age, &1.published_at}

    assert Enum.sort_by(first, & &1.id) |> Enum.map(fields) ==
             Enum.sort_by(second, & &1.id) |> Enum.map(fields)
  end

  test "a non-contained filter misses and falls through" do
    TestPost |> Ash.Query.filter(name == "foo") |> Ash.read!()
    assert pg_reads() == 1

    assert [%{name: "bar"}] =
             TestPost
             |> Ash.Query.filter(name == "bar")
             |> Ash.read!()

    assert pg_reads() == 2
  end

  test "unsupported filter shapes always fall through, correctly" do
    query = Ash.Query.filter(TestPost, contains(name, "fo"))

    assert [_, _] = Ash.read!(query)
    assert_receive {:mdl, [_, :read, :miss], _, %{reason: :solver_unsupported}}
    assert pg_reads() == 1

    # Not recorded: the repeat also falls through.
    assert [_, _] = Ash.read!(query)
    assert pg_reads() == 2
  end

  test "limited reads are served by unlimited coverage but never recorded" do
    # A limited cold read falls through and is NOT recorded.
    assert [_] =
             TestPost
             |> Ash.Query.filter(name == "foo")
             |> Ash.Query.sort(:age)
             |> Ash.Query.limit(1)
             |> Ash.read!()

    assert pg_reads() == 1

    # Same limited read again: still a miss (nothing was recorded).
    TestPost
    |> Ash.Query.filter(name == "foo")
    |> Ash.Query.sort(:age)
    |> Ash.Query.limit(1)
    |> Ash.read!()

    assert pg_reads() == 2

    # Warm the unlimited filter, then the limited probe is a cache hit with
    # sort/limit applied by the cache layer.
    TestPost |> Ash.Query.filter(name == "foo") |> Ash.read!()
    assert pg_reads() == 3

    assert [%{age: 15}] =
             TestPost
             |> Ash.Query.filter(name == "foo")
             |> Ash.Query.sort(:age)
             |> Ash.Query.limit(1)
             |> Ash.read!()

    assert pg_reads() == 3
  end

  test "range and set subsumption work end to end" do
    year_start = ~D[2026-01-01]
    year_end = ~D[2026-12-31]
    march = ~D[2026-03-01]
    april = ~D[2026-04-01]

    TestPost
    |> Ash.Query.filter(published_at >= ^year_start and published_at <= ^year_end)
    |> Ash.read!()

    assert pg_reads() == 1

    assert [%{name: "foo"}] =
             TestPost
             |> Ash.Query.filter(published_at >= ^march and published_at < ^april)
             |> Ash.read!()

    assert pg_reads() == 1

    TestPost |> Ash.Query.filter(name in ["foo", "bar"]) |> Ash.read!()
    assert pg_reads() == 2

    assert [%{name: "bar"}] = TestPost |> Ash.Query.filter(name == "bar") |> Ash.read!()
    assert pg_reads() == 2
  end

  test "L4: string range subsumption never trusts byte order across distinct bounds" do
    # `Comp.compare/2` on strings is byte-ordered ('B' = 66 < 'b' = 98), but a
    # SQL source's own collation (typically ICU/locale) may order case
    # differently — `name > "B"` covering `name > "b"` from cache would be a
    # silent, collation-dependent correctness bug (rows the source would
    # actually return, dropped). Warm `name > "B"`, then query `name > "b"` —
    # unfixed: served from cache (pg_reads stays 1, byte order says "B" < "b"
    # so it looks like a superset); fixed: refused, falls through to source.
    TestPost |> Ash.Query.filter(name > "B") |> Ash.read!()
    assert pg_reads() == 1

    TestPost |> Ash.Query.filter(name > "b") |> Ash.read!()
    assert pg_reads() == 2
  end

  test "L4: identical string range bounds still subsume (byte-order-independent)" do
    TestPost |> Ash.Query.filter(name > "aardvark") |> Ash.read!()
    assert pg_reads() == 1

    # Same exact bound, re-queried — always safe under any collation.
    TestPost |> Ash.Query.filter(name > "aardvark") |> Ash.read!()
    assert pg_reads() == 1
  end

  test "L12 item 2: a fingerprint collision does not widen an unrelated entry" do
    # `dedupe_key/1` is a bare :erlang.phash2/1 hash with no disjunct
    # comparison — simulate a real collision (rather than searching for one,
    # infeasible in a fast test) by hand-crafting an entry that shares a
    # real query's fingerprint but carries UNRELATED normalised content and
    # loaded_fields, exactly what a genuine hash collision would look like
    # from do_record/5's point of view. It is the ONLY entry in the ledger
    # (the real one is removed before the real query is replayed), so
    # Enum.find's traversal order can't make the test accidentally pass —
    # a fingerprint-only match has nothing else to find but this one.
    TestPost |> Ash.Query.filter(name == "foo") |> Ash.read!()
    assert [%{fingerprint: fp} = real_entry] = AshMultiDatalayer.Coverage.entries(TestPost, nil)
    :ok = AshMultiDatalayer.Coverage.drop(TestPost, nil, real_entry.id)

    colliding_entry = %{
      real_entry
      | id: make_ref(),
        fingerprint: fp,
        normalised: %{real_entry.normalised | disjuncts: [%{}]},
        loaded_fields: MapSet.new([:id])
    }

    :ok = AshMultiDatalayer.Coverage.insert(TestPost, nil, colliding_entry)

    # Unfixed: do_record/5 matches by fingerprint alone — the only entry
    # in the ledger has the right fingerprint (a collision) but the WRONG
    # normalised content, so it gets incorrectly widened/reused instead of
    # a fresh entry being recorded for this actually-different query.
    TestPost |> Ash.Query.filter(name == "foo") |> Ash.read!()

    entries = AshMultiDatalayer.Coverage.entries(TestPost, nil)
    colliding = Enum.find(entries, &(&1.id == colliding_entry.id))

    # The colliding entry must stay exactly as hand-crafted (never widened
    # by an unrelated query it doesn't actually cover)...
    assert colliding.loaded_fields == MapSet.new([:id])
    # ...and a distinct, correct entry must exist for the real query.
    assert Enum.any?(
             entries,
             &(&1.id != colliding_entry.id and &1.normalised == real_entry.normalised)
           )
  end

  test "tenantless reads use the global partition consistently" do
    TestPost |> Ash.Query.filter(name == "foo") |> Ash.read!()
    assert [%{tenant: nil}] = AshMultiDatalayer.Coverage.entries(TestPost, nil)
  end

  test "cached rows carry the same values as the source of truth" do
    TestPost |> Ash.Query.filter(name == "foo") |> Ash.read!()

    cached =
      TestPost
      |> Ash.Query.filter(name == "foo")
      |> Ash.read!()
      |> Enum.sort_by(& &1.age)

    source =
      MirrorPost
      |> Ash.Query.filter(name == "foo")
      |> Ash.read!()
      |> Enum.sort_by(& &1.age)

    assert Enum.map(cached, &{&1.id, &1.name, &1.age, &1.published_at}) ==
             Enum.map(source, &{&1.id, &1.name, &1.age, &1.published_at})
  end
end
