defmodule AshMultiDatalayer.Integration.ReconcileScopeTest do
  @moduledoc """
  Reconcile-scope pin test (fix-plan Phase 6.5, pass-4's adjudication of
  pass-3 F1): the reconcile-on-record pass is defense in depth for the
  evict-failure residue, and any stale row under a region being freshly
  re-recorded — it is NOT a safety net for invalidation sources that never
  call `on_write/4` at all. Both limits, pinned side by side so the scope
  in the fix plan's Phase 4.2 is executable, not prose.
  """
  use AshMultiDatalayer.DataCase, async: false

  require Ash.Query

  alias AshMultiDatalayer.Coverage
  alias AshMultiDatalayer.Coverage.Invalidation
  alias AshMultiDatalayer.Test.FailingEts
  alias AshMultiDatalayer.Test.Resources.FailingPost

  setup do
    FailingEts.clear!()
    on_exit(fn -> FailingEts.clear!() end)
    :ok
  end

  defp as_failing_post(%MirrorPost{} = m) do
    struct(FailingPost, Map.take(m, [:id, :name, :age, :score, :published_at]))
  end

  test "(a) evict-failure residue converges via reconcile on the next re-recording read" do
    ghost =
      MirrorPost
      |> Ash.Changeset.for_create(:create, %{name: "ghost-a", age: 10})
      |> Ash.create!()

    assert [%{name: "ghost-a"}] =
             FailingPost |> Ash.Query.filter(name == "ghost-a") |> Ash.read!()

    row_before = as_failing_post(ghost)
    FailingEts.fail!(:destroy)
    Ash.destroy!(ghost)

    # The evict fails, but the entry is still dropped (should_drop? doesn't
    # depend on eviction succeeding) — the ghost survives only physically.
    assert Invalidation.on_write(FailingPost, nil, row_before, nil) == 1
    assert Coverage.entries(FailingPost, nil) == []

    FailingEts.clear!()

    # A later recording over the ghost's region: the source correctly
    # excludes it, and reconcile deletes the physical residue — via
    # `Invalidation.on_evict/3` (A3/M-3), which bumps the epoch as part of
    # the same batch that drops covering ledger entries, exactly like every
    # other cache mutation.
    parent = self()
    handler = "reconcile-scope-a-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [[:ash_multi_datalayer, :read, :hit], [:ash_multi_datalayer, :read, :miss]],
      fn event, _measurements, _metadata, _config -> send(parent, {:mdl_read, List.last(event)}) end,
      nil
    )

    try do
      assert [] = FailingPost |> Ash.Query.filter(name == "ghost-a") |> Ash.read!()

      # Known accepted consequence (A3, pass-1 W3): THIS read's own reconcile
      # just evicted the ghost, bumping the epoch — its own `Coverage.record/5`
      # call (epoch0 captured before the bump) now sees `epoch_moved?` and
      # skips recording. So the very NEXT read is a clean MISS, not a hit: it
      # refetches (still correctly empty) and records fresh, clean coverage.
      assert [] = FailingPost |> Ash.Query.filter(name == "ghost-a") |> Ash.read!()
      assert_received {:mdl_read, :miss}

      # Convergence, not luck: only the THIRD read is a genuine coverage hit,
      # and still correctly empty.
      assert [] = FailingPost |> Ash.Query.filter(name == "ghost-a") |> Ash.read!()
      assert_received {:mdl_read, :hit}
    after
      :telemetry.detach(handler)
    end
  end

  test "(b) a forgotten invalidation (on_write never called) is NOT healed by reconcile — only forget! closes it" do
    ghost =
      MirrorPost
      |> Ash.Changeset.for_create(:create, %{name: "ghost-b", age: 10})
      |> Ash.create!()

    assert [%{name: "ghost-b"}] =
             FailingPost |> Ash.Query.filter(name == "ghost-b") |> Ash.read!()

    # External destroy, but NOTHING ever calls on_write/4 — the lost-
    # notification case. The entry survives untouched.
    Ash.destroy!(ghost)
    assert [_] = Coverage.entries(FailingPost, nil)

    # The documented limit: a plain covered read still serves the ghost,
    # exactly like any surviving valid coverage — reconcile is never
    # consulted because nothing re-recorded this region.
    assert [%{name: "ghost-b"}] =
             FailingPost |> Ash.Query.filter(name == "ghost-b") |> Ash.read!()

    # Only the pull-based healer closes it.
    assert :ok = AshMultiDatalayer.forget!(FailingPost, %{id: ghost.id})
    assert Coverage.entries(FailingPost, nil) == []
    assert [] = FailingPost |> Ash.Query.filter(name == "ghost-b") |> Ash.read!()
  end
end
