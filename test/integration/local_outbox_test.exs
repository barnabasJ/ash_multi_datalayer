defmodule AshMultiDatalayer.Integration.LocalOutboxTest do
  @moduledoc """
  Phase 4: the LocalOutbox strategy end-to-end — local-authoritative reads/writes,
  co-committed outbox entries, flush draining to a replication target (a failable
  ETS layer), per-PK FIFO + chain-block-on-park, every resolution verb, sync
  pause/resume, stale-check conflicts, and inbound refresh with the dirty rule.
  """
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :oban_sqlite

  alias AshMultiDatalayer.Orchestrator.LocalOutbox
  alias AshMultiDatalayer.Orchestrator.LocalOutbox.Target
  alias AshMultiDatalayer.Test.FailableLayer

  alias AshMultiDatalayer.Test.LocalOutbox.{
    Domain,
    OutboxEntry,
    Remote,
    StaleWidget,
    StampWidget,
    Widget
  }

  alias AshMultiDatalayer.Test.LocalOutbox.Migrations, as: LoMigrations
  alias AshMultiDatalayer.Test.ObanSqlite.Migrations, as: ObanMigrations
  alias AshMultiDatalayer.Test.ObanSqlite.SkeletonRepo

  @queue :lo_sync

  setup_all do
    FailableLayer.ensure_table!()

    db = Path.join(System.tmp_dir!(), "amd_local_outbox_#{System.unique_integer([:positive])}.db")
    File.rm(db)
    on_exit(fn -> File.rm(db) end)

    start_supervised!({SkeletonRepo, database: db, pool_size: 1, name: SkeletonRepo})
    Ecto.Migrator.up(SkeletonRepo, 1, LoMigrations, log: false)
    Ecto.Migrator.up(SkeletonRepo, 2, ObanMigrations.ObanJobsTable, log: false)

    start_supervised!(
      {Oban,
       name: Oban,
       engine: Oban.Engines.Lite,
       repo: SkeletonRepo,
       testing: :manual,
       queues: [{@queue, 5}],
       plugins: [{Oban.Plugins.Cron, crontab: []}]}
    )

    :ok
  end

  setup do
    for t <- ~w(lo_widgets lo_stale_widgets lo_stamp_widgets lo_mt_widgets lo_outbox oban_jobs) do
      Ecto.Adapters.SQL.query!(SkeletonRepo, "DELETE FROM #{t}", [])
    end

    # Disarm first, then clear the Remote (ETS-backed) target explicitly — the
    # wrapped-layer ETS table is not reliably reset by `Ash.DataLayer.Ets.stop/1`.
    FailableLayer.clear(Remote)

    for res <- [Widget, StaleWidget, StampWidget, AshMultiDatalayer.Test.LocalOutbox.MtWidget] do
      {:ok, rows} = Target.read_all(res, :remote)
      Enum.each(rows, &Target.destroy(res, :remote, &1, domain: Domain))
    end

    :ok
  end

  # --- helpers -----------------------------------------------------------

  defp create!(attrs) do
    Widget
    |> Ash.Changeset.for_create(:create, Map.new(attrs), domain: Domain)
    |> Ash.create!()
  end

  defp update!(widget, attrs) do
    widget
    |> Ash.Changeset.for_update(:update, Map.new(attrs), domain: Domain)
    |> Ash.update!()
  end

  defp drain,
    do: Oban.drain_queue(Oban, queue: @queue, with_recursion: true, with_scheduled: true)

  defp entries,
    do: Ash.read!(OutboxEntry, domain: Domain, authorize?: false) |> Enum.sort_by(& &1.seq)

  defp remote(resource \\ Widget), do: elem(Target.read_all(resource, :remote), 1)
  defp local(resource \\ Widget), do: elem(Target.read_all(resource, :local), 1)

  # --- read + write path -------------------------------------------------

  describe "read + write path" do
    test "a write commits locally, co-commits a pending outbox entry, sets outbox_ref" do
      w = create!(name: "a")

      assert w.__metadata__.outbox_ref
      assert [local_row] = local()
      assert local_row.id == w.id
      # the entry is present + pending, and the target is untouched until flush.
      assert [%{state: :pending, op: :create, target: :remote}] = entries()
      assert remote() == []
    end

    test "reads are served from the local layer (target stays empty pre-flush)" do
      w = create!(name: "r")
      assert [%{id: id}] = Ash.read!(Widget, domain: Domain)
      assert id == w.id
      assert remote() == []
    end
  end

  # --- flush drains to the target ---------------------------------------

  describe "flush" do
    test "draining pushes the record to the target and marks the entry :synced" do
      w = create!(name: "f", count: 3)
      assert %{success: n} = drain()
      assert n >= 1

      assert [synced] = entries()
      assert synced.state == :synced
      assert [remote_row] = remote()
      assert remote_row.id == w.id
      assert remote_row.count == 3
    end

    test "await returns :synced once the chain drains" do
      w = create!(name: "aw")
      drain()
      assert LocalOutbox.await(w, timeout: 200) == :synced
    end

    test "status/1 works on a record READ from the local layer (not just a fresh write)" do
      w = create!(name: "st")
      # a record read back from the local layer carries no outbox_ref metadata,
      # yet status/1 must still report its per-record sync state.
      [read_back] = Ash.read!(Widget, domain: Domain)
      assert read_back.id == w.id
      assert LocalOutbox.status(read_back) == :pending

      drain()
      [synced] = Ash.read!(Widget, domain: Domain)
      assert LocalOutbox.status(synced) == :synced
    end
  end

  # --- per-PK FIFO + chain-block ----------------------------------------

  describe "ordering" do
    test "successive writes to one record flush in seq order; target ends at the final state" do
      w = create!(name: "v1", count: 1)
      w = update!(w, count: 2)
      _w = update!(w, count: 3)

      # three entries, seq-ordered, same record.
      assert [e1, e2, e3] = entries()
      assert e1.seq < e2.seq and e2.seq < e3.seq

      drain()
      assert Enum.all?(entries(), &(&1.state == :synced))
      assert [%{count: 3}] = remote()
    end

    test "a parked chain head blocks later entries for the same record" do
      FailableLayer.fail(Remote, :rejected)
      w = create!(name: "blocked")
      _w = update!(w, name: "blocked-2")

      drain()

      es = entries()
      # head parked (:rejected), tail held (:pending) — never flushed past the park.
      assert Enum.find(es, &(&1.op == :create)).state == :parked
      assert Enum.find(es, &(&1.op == :update)).state == :pending
      assert remote() == []
    end
  end

  # --- resolution verbs -------------------------------------------------

  describe "resolution verbs" do
    setup do
      FailableLayer.fail(Remote, :rejected)
      w = create!(name: "res")
      drain()
      [parked] = Enum.filter(entries(), &(&1.state == :parked))
      %{widget: w, parked: parked}
    end

    test "retry re-drains a fixed cause", %{parked: parked} do
      FailableLayer.clear(Remote)
      :ok = LocalOutbox.retry(parked)
      drain()

      assert [%{state: :synced}] = entries()
      assert [%{name: "res"}] = remote()
    end

    test "discard of a create drops the whole chain (loudly)", %{widget: w, parked: parked} do
      _ = update!(w, name: "res-2")
      assert {:ok, %{dropped_chain: true, discarded: n}} = LocalOutbox.discard(parked)
      assert n >= 1
      # only synced entries (none) remain; the pending/parked chain is gone.
      assert Enum.filter(entries(), &(&1.state != :synced)) == []
    end

    test "force pushes blind and clears the entry", %{parked: parked} do
      FailableLayer.clear(Remote)
      assert :ok = LocalOutbox.force(parked)
      assert [%{name: "res"}] = remote()
      assert Enum.filter(entries(), &(&1.state != :synced)) == []
    end

    test "discard_local overwrites the local layer with the replica row", %{
      widget: w,
      parked: parked
    } do
      # put a divergent row in the replica, then let the replica win.
      FailableLayer.clear(Remote)
      Target.upsert(Widget, :remote, %{w | name: "server-wins", count: 99})

      :ok = LocalOutbox.discard_local(parked)

      assert [%{name: "server-wins", count: 99}] = local()
      assert Enum.filter(entries(), &(&1.state != :synced)) == []
    end
  end

  # --- sync control ------------------------------------------------------

  describe "pause / resume" do
    # Under Oban's :manual testing mode queues never auto-run, so jobs accumulate
    # regardless — which lets us assert the accumulate → resume → drain sequence
    # deterministically. The levers themselves must succeed and not crash.
    test "writes accumulate; resume + drain flushes them" do
      assert :ok = LocalOutbox.pause_sync(Widget)
      assert is_boolean(LocalOutbox.sync_paused?(Widget))

      w1 = create!(name: "p1")
      w2 = create!(name: "p2")

      # nothing has drained yet — both entries are still pending.
      assert Enum.all?(entries(), &(&1.state == :pending))
      assert remote() == []

      assert :ok = LocalOutbox.resume_sync(Widget)
      drain()

      assert Enum.all?(entries(), &(&1.state == :synced))
      assert MapSet.new(remote(), & &1.id) == MapSet.new([w1.id, w2.id])
    end
  end

  # --- conflict detection (stale-check) ----------------------------------

  describe "stale-check conflict detection" do
    test "a diverged replica parks the flush as :conflict with the remote snapshot" do
      s =
        StaleWidget
        |> Ash.Changeset.for_create(:create, %{name: "s", version: 1}, domain: Domain)
        |> Ash.create!()

      drain()
      assert [%{name: "s", version: 1}] = remote(StaleWidget)

      # a concurrent server write bumps the version out from under us.
      Target.upsert(StaleWidget, :remote, %{s | version: 5})

      # local update (base_image version == 1) now conflicts with remote version 5.
      s
      |> Ash.Changeset.for_update(:update, %{name: "s-local"}, domain: Domain)
      |> Ash.update!()

      drain()

      parked = Enum.filter(entries(), &(&1.state == :parked))
      assert [%{error_class: :conflict, remote_snapshot: snap}] = parked
      assert snap["version"] == 5
    end

    test "a clean flush on a DATETIME stale field does not falsely park (JSON round-trip)" do
      # Regression: base_image round-trips through the outbox `:map`/JSON, so a
      # :utc_datetime_usec comes back a string while the live remote value dumps to
      # a %DateTime{}. Without normalisation the stale-check compared string vs
      # struct and parked EVERY flush. An undiverged update must sync clean.
      at = ~U[2026-07-05 12:00:00.000000Z]

      s =
        StampWidget
        |> Ash.Changeset.for_create(:create, %{name: "s", seen_at: at}, domain: Domain)
        |> Ash.create!()

      drain()
      assert [%{seen_at: ^at}] = remote(StampWidget)

      # local update, remote seen_at UNCHANGED → no real conflict → must sync.
      s
      |> Ash.Changeset.for_update(:update, %{name: "s2"}, domain: Domain)
      |> Ash.update!()

      drain()

      assert entries() |> Enum.filter(&(&1.state == :parked)) == []
      assert Enum.all?(entries(), &(&1.state == :synced))
      assert [%{name: "s2"}] = remote(StampWidget)
    end

    test "a diverged DATETIME stale field still parks as :conflict" do
      s =
        StampWidget
        |> Ash.Changeset.for_create(:create, %{name: "s", seen_at: ~U[2026-07-05 12:00:00Z]},
          domain: Domain
        )
        |> Ash.create!()

      drain()

      # a concurrent server write bumps seen_at out from under us.
      Target.upsert(StampWidget, :remote, %{s | seen_at: ~U[2026-07-05 18:30:00Z]})

      s
      |> Ash.Changeset.for_update(:update, %{name: "s-local"}, domain: Domain)
      |> Ash.update!()

      drain()

      assert [%{error_class: :conflict}] =
               Enum.filter(entries(), &(&1.state == :parked))
    end

    # B6: `remote_matches_payload?/3` (the fast "already applied" check
    # `check_stale/2` runs BEFORE pushing) compared a freshly-`Snapshot.dump`ed
    # remote (structs) against `entry.payload` (JSON-round-tripped scalars)
    # with no normalization — so it can never match on a DATETIME/decimal
    # field, falling through to the base-image field compare, which then
    # (correctly, on its own terms) sees base_image (the PRE-write snapshot)
    # differ from the remote's CURRENT (already-updated) value and parks a
    # FALSE conflict, even though the remote already holds exactly what this
    # entry would push.
    test "a retry whose target already equals the payload does not falsely park (JSON round-trip)" do
      s =
        StampWidget
        |> Ash.Changeset.for_create(:create, %{name: "s", seen_at: ~U[2026-07-05 12:00:00Z]},
          domain: Domain
        )
        |> Ash.create!()

      drain()

      updated =
        s
        |> Ash.Changeset.for_update(:update, %{name: "s2", seen_at: ~U[2026-07-05 18:30:00Z]},
          domain: Domain
        )
        |> Ash.update!()

      # Simulate the push having already landed on the target (e.g. a worker
      # died after `Target.upsert` succeeded but before the entry was marked
      # `:synced`) — the remote already holds exactly the pending payload.
      Target.upsert(StampWidget, :remote, updated)

      drain()

      assert entries() |> Enum.filter(&(&1.state == :parked)) == []
      assert Enum.all?(entries(), &(&1.state == :synced))
      assert [%{name: "s2", seen_at: ~U[2026-07-05 18:30:00.000000Z]}] = remote(StampWidget)
    end
  end

  # --- inbound refresh ---------------------------------------------------

  describe "refresh" do
    test "refresh pulls replica rows into the local layer" do
      # seed the replica directly (as if another client wrote it).
      id = Ash.UUID.generate()
      Target.upsert(Widget, :remote, %Widget{id: id, name: "external", count: 7})

      assert %{refreshed: 1} = LocalOutbox.refresh(Widget, :all)
      assert [%{id: ^id, name: "external"}] = local()
    end

    test "the ExternalChange notifier drives a LocalOutbox refresh (inbound realtime)" do
      # a realtime transport replays another client's write as a local Ash
      # notification; the strategy-agnostic notifier must route it to the
      # orchestrator's handle_external_change → refresh that PK into local.
      id = Ash.UUID.generate()
      Target.upsert(Widget, :remote, %Widget{id: id, name: "pushed-by-peer", count: 3})

      notification = %Ash.Notifier.Notification{
        resource: Widget,
        data: %Widget{id: id},
        metadata: %{ash_remote: %{origin: :remote}}
      }

      assert :ok = AshMultiDatalayer.Notifiers.ExternalChange.notify(notification)

      assert [%{id: ^id, name: "pushed-by-peer"}] = local()
    end

    test "refresh UPDATES an existing (clean) local row when the remote changed" do
      # a fully-synced local row; another client then changes the same row on the
      # server. A refresh must overwrite the local copy with the newer remote one
      # (the cross-client convergence path) — not just add/delete rows.
      w = create!(name: "orig")
      drain()
      assert entries() |> Enum.all?(&(&1.state == :synced))

      Target.upsert(Widget, :remote, %Widget{id: w.id, name: "changed-elsewhere", count: 9})

      assert %{refreshed: 1} = LocalOutbox.refresh(Widget, :all)
      assert [%{id: id, name: "changed-elsewhere"}] = local()
      assert id == w.id
    end

    test "refresh(pk) mirrors a peer's destroy — removes the local row when the remote is gone" do
      # a synced local row (as if hydrated), then destroyed by another client.
      id = Ash.UUID.generate()
      Target.upsert(Widget, :remote, %Widget{id: id, name: "gonna-go", count: 1})
      assert %{refreshed: 1} = LocalOutbox.refresh(Widget, :all)
      assert [%{id: ^id}] = local()

      # peer destroys it on the remote target
      Target.destroy(Widget, :remote, %Widget{id: id}, domain: Domain)
      refute Enum.any?(remote(), &(&1.id == id))

      # a per-record inbound refresh (what handle_external_change runs) must remove
      # it locally — previously it was a no-op and the row lingered.
      assert %{deleted: 1} = LocalOutbox.refresh(Widget, %{"id" => id})
      refute Enum.any?(local(), &(&1.id == id))
    end

    test "refresh(pk) does NOT delete a dirty local row even if the remote is gone" do
      # local create not yet flushed (dirty), remote has no such row.
      w = create!(name: "mine-unflushed")
      # the dirty-rule wins: no delete, the unflushed local write survives.
      assert %{deleted: 0} = LocalOutbox.refresh(Widget, %{"id" => w.id})
      assert [%{name: "mine-unflushed"}] = local()
    end

    test "refresh skips a dirty PK (non-empty outbox chain) and reports it" do
      w = create!(name: "dirty")
      # divergent replica row for the same PK, but the record has a pending entry.
      Target.upsert(Widget, :remote, %Widget{id: w.id, name: "remote-version", count: 42})

      result = LocalOutbox.refresh(Widget, :all)
      assert %{"id" => w.id} in result.skipped_dirty
      # local keeps the unflushed local write, not the remote version.
      assert [%{name: "dirty"}] = local()
    end
  end

  # --- per-action layer targeting (Phase 4a) ----------------------------

  describe "read_from: context" do
    test "routes the read to the named layer, side-effect-free" do
      w = create!(name: "orig", count: 1)
      drain()
      _w = update!(w, count: 2)

      # normal read is served from the local layer (the fresh local write).
      assert [%{count: 2}] = Ash.read!(Widget, domain: Domain)

      # read_from: :remote observes the replica (still the flushed count 1).
      remote_read =
        Widget
        |> Ash.Query.set_context(%{multi_datalayer: %{read_from: :remote}})
        |> Ash.read!(domain: Domain)

      assert [%{count: 1}] = remote_read

      # side-effect-free: the pending update entry is untouched by the compare-read.
      assert Enum.any?(entries(), &(&1.state == :pending and &1.op == :update))
    end
  end

  describe "write_through: context" do
    test "writes the replica synchronously with no outbox entry" do
      Widget
      |> Ash.Changeset.for_create(:create, %{name: "wt", count: 9}, domain: Domain)
      |> Ash.Changeset.set_context(%{multi_datalayer: %{write_through: true}})
      |> Ash.create!()

      # replica has it immediately (synchronous), local has it, and NO entry was
      # enqueued — the hard "durable on the server or error" guarantee.
      assert [%{name: "wt", count: 9}] = remote()
      assert [%{name: "wt", count: 9}] = local()
      assert entries() == []
    end

    test "drains the record's in-flight chain first, leaving no entries to clobber it" do
      # a create is still in-flight (pending, not yet drained).
      w = create!(name: "inflight", count: 1)
      assert Enum.any?(entries(), &(&1.state == :pending))

      # a write_through update to the same record: the pending create is drained
      # (pushed to the replica + removed), then the update writes synchronously.
      w
      |> Ash.Changeset.for_update(:update, %{count: 5}, domain: Domain)
      |> Ash.Changeset.set_context(%{multi_datalayer: %{write_through: true}})
      |> Ash.update!()

      # both layers end at the write_through state; no queued entry survives to
      # later clobber the direct write.
      assert [%{count: 5}] = remote()
      assert [%{count: 5}] = local()
      assert entries() == []
    end

    test "a replica failure fails the action with nothing left enqueued" do
      FailableLayer.fail(Remote, :rejected)

      assert_raise Ash.Error.Unknown, fn ->
        Widget
        |> Ash.Changeset.for_create(:create, %{name: "wt-fail"}, domain: Domain)
        |> Ash.Changeset.set_context(%{multi_datalayer: %{write_through: true}})
        |> Ash.create!()
      end

      assert entries() == []
    end
  end

  # --- H4 (#14): a stale in-flight flush must not regress the target after
  # write_through's inline drain has already resolved that entry.

  describe "H4: write_through's inline drain vs a stale in-flight flush" do
    test "a worker holding a pre-drain snapshot does not push it after the entry is gone" do
      # V1: an unflushed create — this is exactly what an Oban worker's
      # `worker_read_action :pending` would have loaded.
      w = create!(name: "v1")
      stale_entry = entries() |> List.first()
      assert stale_entry.op == :create

      # write_through for the SAME PK drains this exact entry inline (pushes
      # V1, discards it), then pushes + writes V2 synchronously.
      w
      |> Ash.Changeset.for_update(:update, %{name: "v2"}, domain: Domain)
      |> Ash.Changeset.set_context(%{multi_datalayer: %{write_through: true}})
      |> Ash.update!()

      assert entries() == []
      assert [%{name: "v2"}] = remote()

      # The "worker" now (too late) tries to flush its stale, already-
      # discarded reference. Unfixed code pushes it blindly — `entry` is
      # used as-is, never re-checked — clobbering the target back to V1.
      # Fixed code re-fetches immediately before pushing, finds nothing,
      # and no-ops (whether the surrounding update then errors on the
      # missing row or succeeds as a no-op, the target must be unaffected).
      try do
        stale_entry
        |> Ash.Changeset.for_update(:flush, %{}, domain: Domain)
        |> Ash.update()
      rescue
        _ -> :ok
      end

      assert [%{name: "v2"}] = remote()
    end
  end

  # --- L3 (create-PK drain half): a re-create with the same client-generated
  # PK must drain a pending :destroy for that PK.

  describe "L3: write_through's inline drain keys on the effective (create) PK" do
    test "a re-create with the same client-generated id drains a pending :destroy for it" do
      known_id = Ash.UUID.generate()

      w1 =
        Widget
        |> Ash.Changeset.for_create(:create, %{name: "gen1"}, domain: Domain)
        |> Ash.Changeset.force_change_attribute(:id, known_id)
        |> Ash.create!()

      drain()
      assert [%{name: "gen1"}] = remote()

      w1
      |> Ash.Changeset.for_destroy(:destroy, %{}, domain: Domain)
      |> Ash.destroy!()

      # a pending :destroy entry for known_id, not yet flushed (the earlier
      # create entry is already :synced from the drain above).
      assert [%{op: :destroy, state: :pending}] =
               Enum.filter(entries(), &(&1.state != :synced))

      # Unfixed: `drain_chain_inline`'s PK comes from `changeset.data` (nil
      # for a create), so it searches for a chain keyed by `%{"id" => nil}`
      # — never matches the destroy entry above (keyed by `known_id`) — the
      # stale destroy survives and later deletes the recreated row.
      Widget
      |> Ash.Changeset.for_create(:create, %{name: "gen2"}, domain: Domain)
      |> Ash.Changeset.force_change_attribute(:id, known_id)
      |> Ash.Changeset.set_context(%{multi_datalayer: %{write_through: true}})
      |> Ash.create!()

      assert Enum.filter(entries(), &(&1.state != :synced)) == []
      assert [%{name: "gen2"}] = remote()

      # Nothing left pending to later clobber the recreated row.
      drain()
      assert [%{name: "gen2"}] = remote()
    end
  end

  # --- H3: refresh/3's dirty-check + backfill is atomic vs a co-committed write

  describe "H3: refresh's atomic dirty-check + backfill uses a real DB lock" do
    test "the same repo + mode: :immediate refresh/3 uses genuinely excludes a concurrent writer (not Ash.DataLayer.transaction, a no-op on AshSqlite)" do
      _w = create!(name: "orig")
      drain()

      repo =
        AshMultiDatalayer.Orchestrator.LocalOutbox.Write.co_commit_repo(
          Widget,
          AshSqlite.DataLayer,
          OutboxEntry
        )

      assert repo, "Widget/OutboxEntry must share a co-commit repo for this test to be meaningful"

      test_pid = self()

      # Hold exactly the write lock refresh/3's atomic dirty-check+backfill
      # takes (same repo, same `mode: :immediate`) — proves it is a REAL
      # cross-process SQLite lock. `Ash.DataLayer.transaction` (which the
      # task explicitly rules out) is a no-op on AshSqlite and would NOT
      # exclude a concurrent writer this way.
      holder =
        Task.async(fn ->
          repo.transaction(
            fn ->
              send(test_pid, :locked)

              receive do
                :release -> :ok
              end
            end,
            mode: :immediate
          )
        end)

      assert_receive :locked, 1000

      writer =
        Task.async(fn ->
          repo.transaction(fn -> :attempted_write end, mode: :immediate)
        end)

      # The writer must be BLOCKED behind the held lock, not interleaved.
      assert Task.yield(writer, 300) == nil

      send(holder.pid, :release)
      assert {:ok, {:ok, :ok}} = {:ok, Task.await(holder)}
      assert {:ok, :attempted_write} = Task.await(writer, 3000)
    end

    # The local-read-failure-surfaces-as-{:error,_} repro (H3's #18-sibling)
    # needs a resource whose local layer can be armed to fail reads —
    # `FailableLocalWidget`, aliased in `local_outbox_resolution_test.exs`
    # alongside its M-5 siblings; see that file's H3 describe block.
  end

  # --- H5: multitenant tenant model (`nil` = "IS NULL" vs "unscoped") -----

  describe "H5: multitenant boot hydration / resume / dirty-chain scans" do
    alias AshMultiDatalayer.Test.LocalOutbox.MtWidget
    alias AshMultiDatalayer.TenantKey

    defp mt_create!(attrs) do
      MtWidget
      |> Ash.Changeset.for_create(:create, Map.new(attrs), domain: Domain, tenant: attrs[:org_id])
      |> Ash.create!()
    end

    test "boot hydration (unscoped scan) does not bypass the dirty-chain rule for a real tenant's pending write" do
      w = mt_create!(org_id: "t1", name: "mine-unflushed")

      # Mirrors what `boot_hydrate/1`'s `:on_start` branch now does — pass
      # the unscoped scan sentinel explicitly, not the bare `nil` default.
      # Unfixed code (`nil` -> `is_nil(tenant)`) sees zero pending entries
      # for a multitenant host (every real entry has a real tenant string,
      # never a literal null column) -> reports empty -> bypasses the
      # dirty-chain rule -> the remote-authoritative `:all` reconcile then
      # DELETES this still-pending local write (remote has nothing yet).
      # `:all` scope is authoritative-reconcile: a local row absent from the
      # (empty) remote result is normally DELETED — unless the dirty-chain
      # check (which is what's under test) protects it.
      assert %{deleted: 0} = LocalOutbox.refresh(MtWidget, :all, TenantKey.unscoped())
      assert [%{id: id, name: "mine-unflushed"}] = local(MtWidget)
      assert id == w.id
    end

    test "resume_sync kicks a real tenant's pending backlog, not just a nil-tenant one" do
      _w = mt_create!(org_id: "t1", name: "backlogged")
      assert [%{state: :pending}] = entries()

      assert :ok = LocalOutbox.resume_sync(MtWidget)
      drain()

      assert [%{state: :synced}] = entries()
      assert [%{name: "backlogged"}] = remote(MtWidget)
    end

    test "status reflects a pending tenant-scoped entry" do
      w = mt_create!(org_id: "t1", name: "pending-status")
      assert LocalOutbox.status(w) == :pending

      drain()
      assert LocalOutbox.status(w) == :synced
    end

    # P6: retained regression, expected to PASS regardless of H5 — the
    # sweeper's own scan (`sweeper.ex`) reads the outbox with a plain
    # unscoped `Ash.read!`, never through the H5-affected `tenant_filter/2`;
    # the outbox `tenant` column is a regular attribute to that read, so it
    # already returns every tenant's entries. Guards against a future
    # regression that scopes the sweeper's read the same way H5 fixed
    # LocalOutbox's own tenant_filter.
    test "the sweeper discovers a multitenant (tenant-scoped) pending entry with no live job" do
      pk = Ash.UUID.generate()

      # Bypasses the normal write path's post-commit kick entirely (same
      # "lost kick" simulation as the P6 tests in local_outbox_resolution_
      # test.exs) — a tenant-scoped entry, so the sweep must NOT filter it
      # out the way an is_nil(tenant)-based scan (the H5 defect) would.
      entry =
        OutboxEntry
        |> Ash.Changeset.for_create(
          :enqueue,
          %{
            write_ref: Ash.UUID.generate(),
            resource: Atom.to_string(MtWidget),
            tenant: "t1",
            record_pk: %{"id" => pk},
            op: :create,
            payload: %{"id" => pk, "org_id" => "t1", "name" => "mt-lost-kick"},
            base_image: nil,
            target: :remote
          },
          domain: Domain
        )
        |> Ash.create!(authorize?: false)

      assert entry.state == :pending

      AshMultiDatalayer.Orchestrator.LocalOutbox.Sweeper.run_once([MtWidget])
      drain()

      assert [%{state: :synced}] = Ash.read!(OutboxEntry, domain: Domain, authorize?: false)
      assert [%{name: "mt-lost-kick"}] = remote(MtWidget)
    end
  end
end
