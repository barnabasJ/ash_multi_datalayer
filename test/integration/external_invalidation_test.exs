defmodule AshMultiDatalayer.Integration.ExternalInvalidationTest do
  @moduledoc """
  C4: `Coverage.Invalidation.on_write/4` (the API external invalidation
  sources — e.g. an `ash_remote` realtime-notification bridge — are told to
  call) drops ledger entries but, pre-fix, never the physical row. A later
  re-covering read then resurrects the destroyed/pre-update row as if it
  were live (fix-plan Phase 0.4 / the C4 addendum).

  All writes here go through `MirrorPost` — a plain `AshPostgres` resource
  sharing `mdl_posts` with `TestPost` — to simulate a write arriving from
  *outside* TestPost's own `WriteDispatch` (the exact shape `on_write/4` is
  public for).
  """
  use AshMultiDatalayer.DataCase, async: false

  require Ash.Query

  alias AshMultiDatalayer.Coverage
  alias AshMultiDatalayer.Coverage.Invalidation
  alias AshMultiDatalayer.Test.Resources.TestPost

  defp as_test_post(%MirrorPost{} = m) do
    struct(TestPost, Map.take(m, [:id, :name, :age, :score, :published_at]))
  end

  describe "(a) same-filter shape" do
    test "full-miss path: a re-covering read after an external destroy must not resurrect the row" do
      ghost =
        MirrorPost
        |> Ash.Changeset.for_create(:create, %{name: "ghost", age: 10})
        |> Ash.create!()

      # Warm TestPost's cache: physically materialises `ghost` into ETS and
      # records coverage for the exact filter we'll re-run below.
      assert [%{name: "ghost"}] =
               TestPost |> Ash.Query.filter(name == "ghost") |> Ash.read!()

      row_before = as_test_post(ghost)
      Ash.destroy!(ghost)

      # The external invalidation source does the documented thing.
      Invalidation.on_write(TestPost, nil, row_before, nil)

      # The dropped entry means the ledger is now empty for this filter, so
      # the re-covering read is a full miss/backfill/record cycle.
      assert Coverage.entries(TestPost, nil) == []
      assert [] = TestPost |> Ash.Query.filter(name == "ghost") |> Ash.read!()

      # The critical assertion: the NEXT hit must not serve the ghost row
      # that (pre-fix) is still physically sitting in the cache layer.
      assert [] = TestPost |> Ash.Query.filter(name == "ghost") |> Ash.read!()
    end

    test "remainder path: a re-covering read routed through remainder must not resurrect the row" do
      ghost =
        MirrorPost
        |> Ash.Changeset.for_create(:create, %{name: "ghost", age: 10})
        |> Ash.create!()

      _kept =
        MirrorPost
        |> Ash.Changeset.for_create(:create, %{name: "kept", age: 50})
        |> Ash.create!()

      assert [%{name: "ghost"}] =
               TestPost |> Ash.Query.filter(name == "ghost") |> Ash.read!()

      assert [%{name: "kept"}] =
               TestPost |> Ash.Query.filter(name == "kept") |> Ash.read!()

      row_before = as_test_post(ghost)
      Ash.destroy!(ghost)
      Invalidation.on_write(TestPost, nil, row_before, nil)

      # Only the "kept" entry survives (unrelated to the destroyed row) — its
      # existence routes the re-covering read for "ghost" through
      # remainder_read instead of a plain source_read.
      assert [%{filter: kept_filter}] = Coverage.entries(TestPost, nil)
      refute is_nil(kept_filter)

      assert [] = TestPost |> Ash.Query.filter(name == "ghost") |> Ash.read!()

      # The critical assertion: the next hit must not serve the ghost.
      assert [] = TestPost |> Ash.Query.filter(name == "ghost") |> Ash.read!()
    end
  end

  test "(b) unrelated-remainder shape: a differently-shaped entry's region containing the ghost must not resurrect it" do
    ghost =
      MirrorPost
      |> Ash.Changeset.for_create(:create, %{name: "ghost", age: 10})
      |> Ash.create!()

    _kept =
      MirrorPost
      |> Ash.Changeset.for_create(:create, %{name: "kept", age: 50})
      |> Ash.create!()

    # Both rows fall inside `age > 5`; both get cached physically.
    assert [_, _] = TestPost |> Ash.Query.filter(age > 5) |> Ash.read!()

    row_before = as_test_post(ghost)
    Ash.destroy!(ghost)
    Invalidation.on_write(TestPost, nil, row_before, nil)
    assert Coverage.entries(TestPost, nil) == []

    # A fresh, unrelated-in-identity read of the SAME region, now correct
    # (ghost gone from the source): records a brand new entry for `age > 5`.
    assert [%{name: "kept"}] = TestPost |> Ash.Query.filter(age > 5) |> Ash.read!()

    # The exposing read is a DIFFERENT, broader query than the one that just
    # (re-)established coverage — not implied by it, so it goes through
    # remainder_read, whose covered half (`age > 5`, from the unrelated
    # entry above) is run directly against the cache layer's physical rows.
    result = TestPost |> Ash.Query.filter(age > 0) |> Ash.read!()

    refute Enum.any?(result, &(&1.name == "ghost")),
           "the unrelated entry's covered region resurrected the ghost row: #{inspect(result)}"

    assert Enum.any?(result, &(&1.name == "kept"))
  end

  describe "(c) update-moves-region variant" do
    test "a covered read of the vacated region must not serve pre-update values" do
      mover =
        MirrorPost
        |> Ash.Changeset.for_create(:create, %{name: "mover", age: 10})
        |> Ash.create!()

      # Warm coverage for the region the row currently occupies.
      assert [%{age: 10}] = TestPost |> Ash.Query.filter(age > 5) |> Ash.read!()

      row_before = as_test_post(mover)

      # External update moves the row OUT of the covered region.
      updated =
        mover
        |> Ash.Changeset.for_update(:update, %{age: 1})
        |> Ash.update!()

      row_after = as_test_post(updated)

      Invalidation.on_write(TestPost, nil, row_before, row_after)
      assert Coverage.entries(TestPost, nil) == []

      # Re-covering read of the vacated region: the source of truth
      # correctly excludes the row now.
      assert [] = TestPost |> Ash.Query.filter(age > 5) |> Ash.read!()

      # The critical assertion: the next hit must not serve the STALE
      # pre-update physical row still sitting in the cache layer.
      assert [] = TestPost |> Ash.Query.filter(age > 5) |> Ash.read!()
    end
  end
end
