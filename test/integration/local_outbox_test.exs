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
    for t <- ~w(lo_widgets lo_stale_widgets lo_stamp_widgets lo_outbox oban_jobs) do
      Ecto.Adapters.SQL.query!(SkeletonRepo, "DELETE FROM #{t}", [])
    end

    # Disarm first, then clear the Remote (ETS-backed) target explicitly — the
    # wrapped-layer ETS table is not reliably reset by `Ash.DataLayer.Ets.stop/1`.
    FailableLayer.clear(Remote)

    for res <- [Widget, StaleWidget, StampWidget] do
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

      notification = %Ash.Notifier.Notification{resource: Widget, data: %Widget{id: id}}
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
end
