defmodule AshMultiDatalayer.Integration.FieldCoverageTest do
  @moduledoc false
  use AshMultiDatalayer.DataCase, async: false

  require Ash.Query

  alias AshMultiDatalayer.Test.Resources.{MirrorPost, TestPost}

  # Seed OUT OF BAND (directly into Postgres via MirrorPost) so the cache is
  # populated only by read backfill, not write propagation.
  defp seed!(attrs) do
    MirrorPost
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!()
  end

  test "full hit: filter references a field not in the recorded select" do
    seed!(%{name: "alice", age: 30})

    query =
      TestPost
      |> Ash.Query.filter(age > 18)
      |> Ash.Query.select([:name])

    first = Ash.read!(query)
    assert length(first) == 1, "first (source) read should find the row"

    second = Ash.read!(query)

    assert Enum.map(second, & &1.name) == Enum.map(first, & &1.name),
           "second (cache-hit) read must return the same rows as the first"
  end

  test "remainder read serves cache rows recorded with a narrower select" do
    seed!(%{name: "x", age: 30})
    seed!(%{name: "y", age: 40})

    # Read 1: narrow select, records coverage for name == "x" with
    # loaded_fields {id, name} only.
    narrow =
      TestPost
      |> Ash.Query.filter(name == "x")
      |> Ash.Query.select([:name])

    assert [_] = Ash.read!(narrow)

    # Read 2: full select, partially covered (name == "x" is cached).
    wide = Ash.Query.filter(TestPost, name in ["x", "y"])
    rows = Ash.read!(wide)

    ages = rows |> Enum.map(&{&1.name, &1.age}) |> Enum.sort()

    assert ages == [{"x", 30}, {"y", 40}],
           "remainder read returned wrong field values: #{inspect(ages)}"
  end

  test "remainder read drops rows when Q filters on a field the cache entry never loaded" do
    seed!(%{name: "x", age: 30})

    narrow =
      TestPost
      |> Ash.Query.filter(name == "x")
      |> Ash.Query.select([:name])

    assert [_] = Ash.read!(narrow)

    wide = TestPost |> Ash.Query.filter((name == "x" or name == "zzz") and age > 18)
    rows = Ash.read!(wide)

    assert length(rows) == 1,
           "row matching Q was silently dropped by the remainder read"
  end

  test "an opaque calc-ref filter must never reach the remainder split (review-2 F3)" do
    seed!(%{name: "a", age: 20})

    # Warm unrelated coverage so `coverage_split` is non-:none and the
    # remainder planner has a region to (wrongly, pre-fix) split against.
    assert [_] = TestPost |> Ash.Query.filter(age > 0) |> Ash.read!()

    parent = self()
    handler = "opaque-calc-filter-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [
        [:ash_multi_datalayer, :read, :miss],
        [:ash_multi_datalayer, :read, :partial]
      ],
      fn event, _measurements, metadata, _ -> send(parent, {:mdl, event, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    # `adult?` is a locally-evaluable calc, but its ref inside a filter is
    # opaque to the SOLVER (never inlined/expanded) — the full-hit path is
    # already proven safe (opaque => never a hit); this pins that the
    # remainder path must fall through WHOLE too, never split on it.
    result =
      TestPost |> Ash.Query.filter(adult? == true and age > 0) |> Ash.read!()

    assert Enum.map(result, & &1.name) == ["a"]

    assert_receive {:mdl, [_, :read, :miss], %{reason: :solver_unsupported}}
    refute_receive {:mdl, [_, :read, :partial], _}
  end
end
