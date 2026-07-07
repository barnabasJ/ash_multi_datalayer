defmodule AshMultiDatalayer.Integration.ReconcileEpochRaceTest do
  @moduledoc """
  M-3 (fix-plan Phase A0-3 / A3): reconcile's ghost eviction must participate
  in the epoch protocol, exactly like every other cache mutation.

  Race: reader R1 starts a full-miss read of Q, fetching from source BEFORE a
  matching row `r` exists (its `fetched_pks` will never include `r`). While
  R1 is paused inside reconcile's cache-layer scan, a writer creates `r`
  (bumping the epoch and propagating `r` into the cache), and a second
  reader (R2) independently reads Q, backfills `r`, and records a fresh
  coverage entry P covering Q (P postdates the epoch bump, so recording
  succeeds). R1 then resumes: its reconcile scan now genuinely observes `r`
  in the cache, but since `r` isn't in R1's own (stale) `fetched_pks`, R1
  treats it as a ghost.

  Pre-fix, reconcile has no epoch awareness at all: it silently destroys `r`
  and leaves P orphaned, claiming a region that a follow-up read on P then
  serves as an incorrect, silent, LASTING empty result — `r` is gone from
  the cache, but genuinely still exists at the source. Post-fix (A3),
  reconcile's ghost eviction reuses `Invalidation.on_write`'s machinery: it
  bumps the epoch and drops every covering ledger entry (including P) in the
  same batch, so the very next read on Q is a clean MISS — it refetches `r`
  from source, backfills, and records fresh coverage — and only the read
  AFTER THAT is a genuine hit.
  """
  use AshMultiDatalayer.DataCase, async: false

  require Ash.Query

  alias AshMultiDatalayer.Coverage
  alias AshMultiDatalayer.Test.BlockingLayer
  alias AshMultiDatalayer.Test.ReconcileBlockingEts
  alias AshMultiDatalayer.Test.Resources.ReconcileRaceTestPost

  setup do
    BlockingLayer.reset!()
    :ok
  end

  defp as_reconcile_post(%MirrorPost{} = m) do
    struct(ReconcileRaceTestPost, Map.take(m, [:id, :name, :age, :score, :published_at]))
  end

  test "a reconcile racing a concurrent create must not orphan coverage over the live row" do
    name = "ghost-race-#{System.unique_integer([:positive])}"
    query = ReconcileRaceTestPost |> Ash.Query.filter(name == ^name)

    assert Coverage.entries(ReconcileRaceTestPost, nil) == []

    BlockingLayer.arm(ReconcileBlockingEts)
    task = Task.async(fn -> Ash.read!(query) end)

    assert_receive {:blocking_layer_parked, ReconcileBlockingEts, reader_pid}, 1000

    # The writer creates the matching row through the NORMAL write path —
    # this bumps the epoch and propagates the row into the cache layer.
    mirror =
      MirrorPost
      |> Ash.Changeset.for_create(:create, %{name: name, age: 5})
      |> Ash.create!()

    row = as_reconcile_post(mirror)

    # A second, independent reader: ledger is still empty (R1 hasn't
    # recorded anything yet), so this is its own full miss too — it fetches
    # the row from source, backfills it into the cache, reconciles cleanly
    # (its OWN fetched_pks includes the row), and records fresh coverage P.
    assert [%{id: row_id}] = Ash.read!(query)
    assert row_id == row.id
    assert [_p] = Coverage.entries(ReconcileRaceTestPost, nil)

    # Release R1: its reconcile scan runs for real NOW, genuinely observing
    # the row in the cache — but R1's OWN fetched_pks predates the write, so
    # (pre-fix) it wrongly treats the row as a ghost and destroys it, with
    # no epoch/ledger awareness at all.
    BlockingLayer.release(ReconcileBlockingEts, reader_pid)
    Task.await(task)

    # The load-bearing assertion (pass-2 C1): a follow-up identical read
    # must never silently, lastingly serve an empty result for a row that
    # genuinely still exists at the source. Pre-fix this is a HIT on the
    # orphaned entry P, returning [] — the bug. Post-fix it is a clean MISS
    # that refetches and re-records.
    parent = self()
    handler = "reconcile-epoch-race-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [
        [:ash_multi_datalayer, :read, :hit],
        [:ash_multi_datalayer, :read, :miss]
      ],
      fn event, _measurements, _metadata, _config ->
        send(parent, {:mdl_read, List.last(event)})
      end,
      nil
    )

    try do
      assert [%{id: follow_up_id}] = Ash.read!(query)
      assert follow_up_id == row.id
      assert_received {:mdl_read, :miss}

      # A THIRD read now genuinely hits the freshly-recorded coverage.
      assert [%{id: third_id}] = Ash.read!(query)
      assert third_id == row.id
      assert_received {:mdl_read, :hit}
    after
      :telemetry.detach(handler)
    end
  end
end
