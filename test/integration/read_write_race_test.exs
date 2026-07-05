defmodule AshMultiDatalayer.Integration.ReadWriteRaceTest do
  @moduledoc """
  C3: a read-miss backfill racing a concurrent write must never record stale
  rows or stale coverage (fix-plan Phase 0.3). Both shapes are made
  deterministic via `AshMultiDatalayer.Test.BlockingLayer`, never sleeps.
  """
  use AshMultiDatalayer.DataCase, async: false

  require Ash.Query

  alias AshMultiDatalayer.Coverage
  alias AshMultiDatalayer.Test.{BlockingEts, BlockingLayer, BlockingPostgres}
  alias AshMultiDatalayer.Test.Resources.RaceTestPost

  setup do
    BlockingLayer.reset!()
    :ok
  end

  # The racing writer must never touch the blocking layers' `run_query` (only
  # reads do) — build its changeset from a plain MirrorPost load, which never
  # goes anywhere near RaceTestPost's layers.
  defp as_race_post(%MirrorPost{} = m) do
    struct(RaceTestPost, Map.take(m, [:id, :name, :age, :score, :published_at]))
  end

  describe "full-miss shape" do
    test "a write racing an in-flight source-read backfill never records stale coverage" do
      mirror =
        MirrorPost
        |> Ash.Changeset.for_create(:create, %{name: "bar", age: 20})
        |> Ash.create!()

      race_query = RaceTestPost |> Ash.Query.filter(name == "bar")

      # Cold ledger: this read will be a plain source_read (no existing
      # coverage, so remainder_plan is :none too).
      assert Coverage.entries(RaceTestPost, nil) == []

      BlockingLayer.arm(BlockingPostgres)
      task = Task.async(fn -> Ash.read!(race_query) end)

      assert_receive {:blocking_layer_parked, BlockingPostgres, reader_pid}, 1000

      # Writer commits through the full WriteDispatch sequence while the
      # reader is parked holding the PRE-write rows (age: 20). This is the
      # classic zero-drop case: the ledger has nothing for Q yet.
      mirror
      |> as_race_post()
      |> Ash.Changeset.for_update(:update, %{age: 21})
      |> Ash.update!()

      BlockingLayer.release(BlockingPostgres, reader_pid)
      result = Task.await(task)

      # The raced read itself is a valid snapshot of pre-write state.
      assert Enum.map(result, & &1.age) == [20]

      # Entry-resurrection check FIRST, before any further read (a later
      # healing read legitimately re-records Q and would make this assertion
      # meaningless if checked afterwards).
      assert Coverage.entries(RaceTestPost, nil) == [],
             "the raced backfill must not have recorded coverage for Q"

      # Only now does the follow-up identical read run — it must return the
      # WRITTEN value, never the stale snapshot the race captured.
      assert [%{age: 21}] = Ash.read!(race_query)
    end
  end

  describe "remainder shape" do
    test "a write racing the cache-side region fetch never poisons the merged/recorded result" do
      mirror =
        MirrorPost
        |> Ash.Changeset.for_create(:create, %{name: "foo", age: 999})
        |> Ash.create!()

      # Warm unrelated coverage (age == 999) so `coverage_split` is non-:none
      # for the racy query below, routing it through remainder_read instead
      # of a plain source_read.
      assert [%{name: "foo"}] =
               RaceTestPost |> Ash.Query.filter(age == 999) |> Ash.read!()

      # Not implied by the age==999 entry, so this filter misses full
      # coverage and (since a coverage region now exists) routes through
      # remainder_read instead of a plain source_read.
      race_query = RaceTestPost |> Ash.Query.filter(name == "foo")

      BlockingLayer.arm(BlockingEts)
      task = Task.async(fn -> Ash.read!(race_query) end)

      assert_receive {:blocking_layer_parked, BlockingEts, reader_pid}, 1000

      # The write moves the row OUT of Q (name changes away from "foo")
      # while it stays inside the covered region C (age stays 999). The
      # reader's cache-side fetch already captured the OLD row (matching Q)
      # before this write landed.
      mirror
      |> as_race_post()
      |> Ash.Changeset.for_update(:update, %{name: "foo2"})
      |> Ash.update!()

      BlockingLayer.release(BlockingEts, reader_pid)
      result = Task.await(task)

      # The row no longer matches Q post-write; the merged/caller-visible
      # result must not resurrect it via the stale cache-half fetch.
      assert result == []

      # Entry-resurrection check first: no coverage for Q was recorded from
      # the raced backfill (and the age==999 entry the write's before-image
      # matched should be gone too, via ordinary row-aware invalidation).
      assert Coverage.entries(RaceTestPost, nil) == [],
             "the raced remainder backfill must not have recorded coverage for Q"

      # Follow-up identical read reflects the write.
      assert [] = Ash.read!(race_query)
    end
  end
end
