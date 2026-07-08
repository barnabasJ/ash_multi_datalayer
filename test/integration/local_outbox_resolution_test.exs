defmodule AshMultiDatalayer.Integration.LocalOutboxResolutionTest do
  @moduledoc """
  Fix-plan Phase A0: regression harness for the whole-repo review's LocalOutbox
  findings (M-1, M-2, M-4, M-5, M-6, M-12). Tests 1–6 (rebase, write_through
  local-state-on-failure, the taxonomy, the no-co-commit config, and
  `discard_local`) must fail pre-fix for the reasons the review documents;
  7–8 (boot hydration, `chain_position` `:blocked`) are gap-fill/arbitration —
  their sub-assertions may already be green and must stay green post-fix.
  """
  use ExUnit.Case, async: false

  require Ash.Query
  import ExUnit.CaptureLog

  @moduletag :integration
  @moduletag :oban_sqlite

  alias AshMultiDatalayer.Backfill
  alias AshMultiDatalayer.Orchestrator.LocalOutbox
  alias AshMultiDatalayer.Orchestrator.LocalOutbox.{Flush, Sweeper, Target}
  alias AshMultiDatalayer.Test.FailableLayer

  alias AshMultiDatalayer.Test.LocalOutbox.{
    Domain,
    FailableLocalWidget,
    FailableSqlite,
    FailableTarget,
    IfEmptyWidget,
    MtWidget,
    OutboxEntry,
    Remote,
    TimestampWidget,
    Widget
  }

  alias AshMultiDatalayer.Test.LocalOutbox.Migrations, as: LoMigrations
  alias AshMultiDatalayer.Test.ObanSqlite.Migrations, as: ObanMigrations
  alias AshMultiDatalayer.Test.ObanSqlite.SkeletonRepo

  @queue :lo_sync

  setup_all do
    FailableLayer.ensure_table!()

    db =
      Path.join(
        System.tmp_dir!(),
        "amd_local_outbox_resolution_#{System.unique_integer([:positive])}.db"
      )

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
    for t <-
          ~w(lo_widgets lo_timestamp_widgets lo_ifempty_widgets lo_failable_local_widgets lo_mt_widgets lo_outbox oban_jobs) do
      Ecto.Adapters.SQL.query!(SkeletonRepo, "DELETE FROM #{t}", [])
    end

    FailableLayer.clear(Remote)
    FailableLayer.clear(FailableTarget)
    FailableLayer.clear(FailableSqlite)

    for {res, target} <- [{Widget, :remote}, {TimestampWidget, :remote}, {IfEmptyWidget, :remote}] do
      {:ok, rows} = Target.read_all(res, target)
      Enum.each(rows, &Target.destroy(res, target, &1, domain: Domain))
    end

    {:ok, rows} = Target.read_all(FailableLocalWidget, :remote)
    Enum.each(rows, &Target.destroy(FailableLocalWidget, :remote, &1, domain: Domain))

    :ok
  end

  # --- helpers -------------------------------------------------------------

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

  # --- M9: discard/1's create-branch must destroy its chain atomically ------

  # A genuinely mid-chain destroy failure (proving the rollback, not just
  # the happy path) would need an entry to vanish strictly BETWEEN
  # discard/1's internal record_chain/1 read and its destroy loop — both
  # run synchronously in one process with no yield point between them, and
  # OutboxEntry's own :discard action (add_action(:destroy, :discard, [])
  # — no guard) has no hook to fail it deterministically without a
  # test-only production change. destroy_captured_chain/3's rollback
  # behavior on a genuine failure is what rebase/2's OWN test suite above
  # already exercises (same shared helper); this describe block instead
  # proves the missing half — that discard/1's create-branch now calls it
  # at all (a real co-commit repo.transaction) instead of the old bare,
  # unwrapped Enum.each.
  describe "M9: discard/1's create-branch runs inside the real co-commit transaction" do
    test "discards every chain entry (create + subsequent pending writes) via one transaction" do
      FailableLayer.fail(Remote, :rejected)

      w = create!(name: "m9", count: 1)
      drain()
      update!(w, %{name: "m9-2"})

      [head, tail] = entries() |> Enum.sort_by(& &1.seq)
      assert head.state == :parked
      assert head.op == :create

      assert {:ok, %{discarded: 2, dropped_chain: true}} = LocalOutbox.discard(head)
      # Both outbox entries are gone — discard/1 only drops the
      # replication chain; the local authoritative record is untouched.
      assert entries() == []
      assert Enum.any?(local(), &(&1.id == w.id))

      _ = tail
    after
      FailableLayer.clear(Remote)
    end
  end

  # --- M-1: rebase/2 ---------------------------------------------------------

  describe "M-1: rebase/2 must not destroy the entries created by its own resolution write" do
    setup do
      FailableLayer.fail(Remote, :rejected)
      w = create!(name: "conflict", count: 1)
      drain()
      [parked] = Enum.filter(entries(), &(&1.state == :parked))
      FailableLayer.clear(Remote)
      %{widget: w, parked: parked}
    end

    test "rebase enqueues a pending resolution write, drops only the OLD chain, and converges",
         %{widget: w, parked: parked} do
      :ok = LocalOutbox.pause_sync(Widget)

      changeset =
        Ash.Changeset.for_update(w, :update, %{name: "resolved", count: 99}, domain: Domain)

      assert {:ok, _resolved} = LocalOutbox.rebase(parked, changeset)

      # (a) a :pending outbox entry exists for the resolved write immediately
      # after rebase returns — before any flush has had a chance to run. With
      # the current (buggy) apply-then-drop-by-key order this is empty: the
      # fresh entry shares the parked entry's key and gets swept up too.
      fresh_pending = Enum.filter(entries(), &(&1.state == :pending))
      assert fresh_pending != [], "the resolution write must leave a pending outbox entry"

      :ok = LocalOutbox.resume_sync(Widget)
      drain()

      # (b) after a flush the target holds the resolved value.
      assert [%{name: "resolved", count: 99}] = remote()

      # (c) a subsequent refresh(:all) must NOT revert the local resolution.
      assert %{} = LocalOutbox.refresh(Widget, :all)
      assert [%{name: "resolved", count: 99}] = local()
    end

    test "when the resolution changeset fails, the parked entry stays parked and local is unchanged",
         %{parked: parked} do
      w = hd(local())

      bad_changeset =
        Ash.Changeset.for_update(w, :update, %{count: "not-an-integer"}, domain: Domain)

      assert_raise Ash.Error.Invalid, fn -> LocalOutbox.rebase(parked, bad_changeset) end

      assert [%{state: :parked}] = Enum.filter(entries(), &(&1.seq == parked.seq))
      assert [%{name: "conflict", count: 1}] = local()
    end
  end

  # --- M-2: write_through -----------------------------------------------------

  describe "M-2: write_through must leave the local layer untouched on a replica failure" do
    test "a replica failure during write_through leaves the local layer at its PRE-write value" do
      w = create!(name: "before", count: 1)
      drain()
      assert [%{name: "before", count: 1}] = remote()

      FailableLayer.fail(Remote, :rejected)

      assert_raise Ash.Error.Unknown, fn ->
        w
        |> Ash.Changeset.for_update(:update, %{name: "after", count: 99}, domain: Domain)
        |> Ash.Changeset.set_context(%{multi_datalayer: %{write_through: true}})
        |> Ash.update!()
      end

      assert [%{name: "before", count: 1}] = local()
    end

    test "arbitration (gap-fill): a lazy-defaulted PK + timestamp materialize identically on the target" do
      TimestampWidget
      |> Ash.Changeset.for_create(:create, %{name: "ts"}, domain: Domain)
      |> Ash.Changeset.set_context(%{multi_datalayer: %{write_through: true}})
      |> Ash.create!()

      [local_row] = local(TimestampWidget)
      [remote_row] = remote(TimestampWidget)

      assert remote_row.id == local_row.id
      assert remote_row.name == local_row.name
      assert remote_row.inserted_at == local_row.inserted_at
      assert %DateTime{} = local_row.inserted_at
    end

    test "regression (A1-2): a write_through update from a partially-selected record pushes only loaded fields" do
      w = create!(name: "partial", count: 1)
      drain()

      partial =
        Widget
        |> Ash.Query.select([:id, :count])
        |> Ash.Query.filter(id == ^w.id)
        |> Ash.read_one!(domain: Domain)

      partial
      |> Ash.Changeset.for_update(:update, %{count: 5}, domain: Domain)
      |> Ash.Changeset.set_context(%{multi_datalayer: %{write_through: true}})
      |> Ash.update!()

      assert [%{count: 5}] = remote()
      assert [%{count: 5}] = local()
    end
  end

  # --- M-6: flush error taxonomy ----------------------------------------------

  describe "M-6: Flush.classify/1 taxonomy" do
    test "%Ash.Error.Forbidden{} classifies :auth, never :transient" do
      assert Flush.classify(%Ash.Error.Forbidden{}) == :auth
    end

    test "%{class: :forbidden} classifies :auth" do
      assert Flush.classify(%{class: :forbidden}) == :auth
    end

    test "%Ash.Error.Invalid{} still classifies :rejected" do
      assert Flush.classify(%Ash.Error.Invalid{}) == :rejected
    end

    test "an unrecognised error still classifies :transient (retry then park)" do
      assert Flush.classify({:boom, "network gone"}) == :transient
    end
  end

  describe "M-6: a Forbidden target failure parks immediately as :auth, without burning retries" do
    test "parks with error_class: :auth on the first flush attempt" do
      FailableLayer.fail(Remote, :forbidden)
      create!(name: "forbidden-case")
      drain()

      assert [%{state: :parked, error_class: :auth}] = entries()
    end

    test "retry re-flushes an :auth-parked entry once credentials are fixed" do
      FailableLayer.fail(Remote, :forbidden)
      create!(name: "forbidden-case-2")
      drain()
      [parked] = entries()

      FailableLayer.clear(Remote)
      :ok = LocalOutbox.retry(parked)
      drain()

      assert [%{state: :synced}] = entries()
      assert [%{name: "forbidden-case-2"}] = remote()
    end
  end

  # --- M-4: no co-commit repo --------------------------------------------------

  describe "M-4: async write without a co-commit repo" do
    test "validate_opts rejects a LocalOutbox config whose local layer and outbox share no repo" do
      bad =
        define(
          quote do
            multi_data_layer do
              orchestrator(
                {AshMultiDatalayer.Orchestrator.LocalOutbox,
                 outbox_resource: AshMultiDatalayer.Test.LocalOutbox.OutboxEntry, hydrate: :manual}
              )

              layer(:local, Ash.DataLayer.Ets)
              layer(:remote, AshMultiDatalayer.Test.LocalOutbox.Remote)
              read_order([:local])
              write_order([:local, :remote])
            end
          end
        )

      assert error_message(
               AshMultiDatalayer.Verifiers.ValidateOrchestrator.verify(bad.spark_dsl_config())
             ) =~ "co-commit"
    end
  end

  # --- M-5: discard_local -------------------------------------------------------

  describe "M-5: discard_local must propagate a local-write failure" do
    test "when the local write fails, discard_local returns {:error, _} and the entry stays parked" do
      FailableLayer.fail(FailableTarget, :rejected)

      w =
        FailableLocalWidget
        |> Ash.Changeset.for_create(:create, %{name: "dl"}, domain: Domain)
        |> Ash.create!()

      drain()

      _ = w

      assert [parked] =
               OutboxEntry
               |> Ash.read!(domain: Domain, authorize?: false)
               |> Enum.filter(&(&1.state == :parked))

      # target now healthy (irrelevant — discard_local never touches it once
      # the target read comes back nil), LOCAL layer now fails instead.
      FailableLayer.clear(FailableTarget)
      FailableLayer.fail(FailableSqlite, :rejected)

      assert {:error, _} = LocalOutbox.discard_local(parked)

      still_there =
        OutboxEntry
        |> Ash.read!(domain: Domain, authorize?: false)
        |> Enum.filter(&(&1.seq == parked.seq))

      assert [%{state: :parked}] = still_there
    after
      FailableLayer.clear(FailableSqlite)
      FailableLayer.clear(FailableTarget)
    end
  end

  # --- M4: discard_local must capture its chain BEFORE applying, not re-read ----

  describe "M4: discard_local captures its chain before the local write, mirroring rebase/2" do
    test "a write landing between the local write and the chain destroy survives with its pending entry intact" do
      FailableLayer.fail(FailableTarget, :rejected)

      w =
        FailableLocalWidget
        |> Ash.Changeset.for_create(:create, %{name: "dl-race"}, domain: Domain)
        |> Ash.create!()

      drain()

      assert [parked] =
               OutboxEntry
               |> Ash.read!(domain: Domain, authorize?: false)
               |> Enum.filter(&(&1.state == :parked))

      FailableLayer.clear(FailableTarget)

      # Fires exactly during discard_local's local write (Backfill.
      # upsert_record against FailableSqlite) — an ordinary write on the
      # SAME record landing in that window creates a fresh :pending entry
      # sharing this exact chain key. Unfixed: discard_local's destroy step
      # re-reads the chain AFTER this point (drop_chain/1) and destroys the
      # fresh entry too — the concurrent write's replication entry is gone
      # with no trace.
      FailableLayer.run_before(FailableSqlite, fn ->
        w
        |> Ash.Changeset.for_update(:update, %{name: "dl-race-2"}, domain: Domain)
        |> Ash.update!()
      end)

      assert :ok = LocalOutbox.discard_local(parked)

      fresh =
        OutboxEntry
        |> Ash.read!(domain: Domain, authorize?: false)
        |> Enum.filter(&(&1.state == :pending))

      assert fresh != [], "the concurrent write's pending entry must survive discard_local"
    after
      FailableLayer.clear(FailableTarget)
      FailableLayer.clear_before(FailableSqlite)
    end

    test "discard_local rejects a :pending (never-parked) entry" do
      w =
        FailableLocalWidget
        |> Ash.Changeset.for_create(:create, %{name: "dl-pending"}, domain: Domain)
        |> Ash.create!()

      [pending] =
        OutboxEntry
        |> Ash.read!(domain: Domain, authorize?: false)
        |> Enum.filter(&(&1.record_pk["id"] == w.id))

      assert pending.state == :pending
      assert {:error, :not_parked} = LocalOutbox.discard_local(pending)
    end

    test "discard_local rejects a parked entry that is not the chain head" do
      FailableLayer.fail(FailableTarget, :rejected)

      w =
        FailableLocalWidget
        |> Ash.Changeset.for_create(:create, %{name: "dl-blocked"}, domain: Domain)
        |> Ash.create!()

      drain()

      w
      |> Ash.Changeset.for_update(:update, %{name: "dl-blocked-2"}, domain: Domain)
      |> Ash.update!()

      [head, tail] =
        OutboxEntry
        |> Ash.read!(domain: Domain, authorize?: false)
        |> Enum.filter(&(&1.record_pk["id"] == w.id))
        |> Enum.sort_by(& &1.seq)

      assert head.state == :parked
      # Only the chain head is ever actively flushed under normal operation
      # — a non-head entry can't organically reach :parked. Force it
      # directly (the same :park action record_divergence/5 uses) to
      # exercise ensure_resolvable_head's chain_head? branch specifically,
      # as opposed to its earlier (already-covered) :not_parked branch.
      tail =
        tail
        |> Ash.Changeset.for_update(:park, %{error_class: :conflict}, domain: Domain)
        |> Ash.update!(authorize?: false)

      assert tail.state == :parked

      assert {:error, :not_chain_head} = LocalOutbox.discard_local(tail)
    after
      FailableLayer.clear(FailableTarget)
    end

    test "the remote-gone branch carries the entry's tenant into the local destroy" do
      FailableLayer.fail(Remote, :rejected)

      w =
        MtWidget
        |> Ash.Changeset.for_create(:create, %{org_id: "acme", name: "dl-mt"}, domain: Domain)
        |> Ash.create!()

      drain()

      assert [parked] =
               OutboxEntry
               |> Ash.read!(domain: Domain, authorize?: false)
               |> Enum.filter(&(&1.record_pk["id"] == w.id and &1.state == :parked))

      FailableLayer.clear(Remote)

      # The target never held this row (parked immediately), so
      # Target.read_pk returns {:ok, nil} — the remote-gone branch, whose
      # local destroy must carry entry.tenant ("acme"). Unfixed:
      # backfill_opts(host) with no tenant either fails to find the
      # attribute-multitenant row at all (leaving it behind) or drops it
      # from the wrong scope.
      assert :ok = LocalOutbox.discard_local(parked)

      assert [] =
               MtWidget
               |> Ash.Query.for_read(:read, %{}, domain: Domain, tenant: "acme")
               |> Ash.Query.filter(id == ^w.id)
               |> Ash.read!(authorize?: false)
    after
      FailableLayer.clear(Remote)
    end

    # F2 (pass-3a review): retained regression, not a repro — discard_local's
    # `Target.read_pk` call was ALREADY a soft `case`/`{:error, _} = error`
    # match before M4 (never a hard `{:ok, _} =` match that would raise);
    # this is Cat B coverage for that pre-existing-but-untested safety, not
    # a new fix.
    test "a Target.read_pk failure surfaces as {:error, _}, never a raise" do
      FailableLayer.fail(FailableTarget, :rejected)

      w =
        FailableLocalWidget
        |> Ash.Changeset.for_create(:create, %{name: "dl-readfail"}, domain: Domain)
        |> Ash.create!()

      drain()

      assert [parked] =
               OutboxEntry
               |> Ash.read!(domain: Domain, authorize?: false)
               |> Enum.filter(&(&1.record_pk["id"] == w.id and &1.state == :parked))

      FailableLayer.fail_reads(FailableTarget, {:rejected, "target read failed"})

      assert {:error, _} = LocalOutbox.discard_local(parked)
    after
      FailableLayer.clear(FailableTarget)
      FailableLayer.clear_reads(FailableTarget)
    end
  end

  # --- M6: destroy-flush of an already-gone row must not park ---------------

  describe "M6: destroy_record maps an already-absent row to :ok, not an error" do
    test "a local StaleRecord (zero-row delete) maps to :ok" do
      w =
        FailableLocalWidget
        |> Ash.Changeset.for_create(:create, %{name: "gone"}, domain: Domain)
        |> Ash.create!()

      # Delete it directly against the SQLite layer, bypassing the outbox.
      assert :ok = Backfill.destroy_record(FailableSqlite, FailableLocalWidget, w, domain: Domain)

      # Unfixed: the row is already gone, so this second delete hits a
      # zero-row StaleRecord and destroy_record returns {:error, _}.
      assert :ok = Backfill.destroy_record(FailableSqlite, FailableLocalWidget, w, domain: Domain)
    end

    test "a remote NotFound-class error maps to :ok" do
      w =
        FailableLocalWidget
        |> Ash.Changeset.for_create(:create, %{name: "gone-remote"}, domain: Domain)
        |> Ash.create!()

      FailableLayer.fail(FailableTarget, :not_found)

      assert :ok = Backfill.destroy_record(FailableTarget, FailableLocalWidget, w, domain: Domain)
    after
      FailableLayer.clear(FailableTarget)
    end

    test "a genuine destroy rejection still surfaces as an error" do
      w =
        FailableLocalWidget
        |> Ash.Changeset.for_create(:create, %{name: "still-invalid"}, domain: Domain)
        |> Ash.create!()

      FailableLayer.fail(FailableTarget, :rejected)

      assert {:error, _} =
               Backfill.destroy_record(FailableTarget, FailableLocalWidget, w, domain: Domain)
    after
      FailableLayer.clear(FailableTarget)
    end

    test "end-to-end: a destroy flush against an already-gone remote row marks :synced, not :rejected" do
      w =
        FailableLocalWidget
        |> Ash.Changeset.for_create(:create, %{name: "gone-e2e"}, domain: Domain)
        |> Ash.create!()

      drain()

      # The target row is already gone (a prior flush attempt succeeded
      # there, simulated directly) before this entry's own destroy-flush
      # ever runs — the same "already absent" condition a retry-after-crash
      # would hit. NOTE: this target is ETS-backed (FailableTarget wraps
      # Ash.DataLayer.Ets), which does not error on a missing-key destroy —
      # so unlike the two unit tests above, this specific scenario does
      # NOT fail on unfixed code (ETS never reaches destroy_record's error
      # branch at all). Kept as end-to-end wiring confirmation that the
      # fixed destroy_record's :ok result flows correctly through
      # Flush.push -> classify -> :synced, not as an independent repro.
      Target.destroy(FailableLocalWidget, :remote, w, domain: Domain)

      Ash.destroy!(w)
      drain()

      [destroy_entry] =
        OutboxEntry
        |> Ash.read!(domain: Domain, authorize?: false)
        |> Enum.filter(&(&1.op == :destroy))

      # Against a REAL SQLite or remote target, unfixed code would hit
      # {:error, %StaleRecord{}} (or a not_found-class error), classify/1
      # would map it to :rejected, and the entry would park — demanding an
      # discard/1 for a destroy that already took effect.
      assert destroy_entry.state == :synced
    end
  end

  # --- M-12: boot hydration ------------------------------------------------------

  describe "M-12: boot hydration (hydrate: :on_start / :if_empty)" do
    test "on_start seeds an empty local layer from the replication target" do
      seed = %FailableLocalWidget{id: Ash.UUID.generate(), name: "seeded"}
      {:ok, _} = Target.upsert(FailableLocalWidget, :remote, seed)

      assert local(FailableLocalWidget) == []

      run_boot_hydrate!(FailableLocalWidget)

      assert [%{id: id, name: "seeded"}] = local(FailableLocalWidget)
      assert id == seed.id
    end

    test "if_empty skips a host with a non-empty (unflushed) outbox" do
      w =
        IfEmptyWidget
        |> Ash.Changeset.for_create(:create, %{name: "mine"}, domain: Domain)
        |> Ash.create!()

      Target.upsert(IfEmptyWidget, :remote, %IfEmptyWidget{id: w.id, name: "clobbered?"})

      run_boot_hydrate!(IfEmptyWidget)

      assert [%{name: "mine"}] = local(IfEmptyWidget)
    end

    test "a failing hydrate logs a warning and still returns (never crashes boot)" do
      {:ok, _} =
        Target.upsert(FailableLocalWidget, :remote, %FailableLocalWidget{
          id: Ash.UUID.generate(),
          name: "x"
        })

      FailableLayer.fail(FailableSqlite, :rejected)

      log =
        capture_log(fn ->
          run_boot_hydrate!(FailableLocalWidget)
        end)

      assert log =~ "FailableLocalWidget" or log =~ "hydrate"
    after
      FailableLayer.clear(FailableSqlite)
    end
  end

  describe "M-12: chain_position :blocked + recovery unblocks the chain" do
    test "a parked ancestor holds later entries at :blocked; resolving the head unblocks them" do
      FailableLayer.fail(Remote, :rejected)
      w = create!(name: "chain-block")
      _w2 = update!(w, name: "chain-block-2")
      drain()

      [head, tail] = entries()
      assert head.state == :parked
      assert tail.state == :pending
      assert Flush.chain_position(OutboxEntry, Domain, tail) == :blocked

      FailableLayer.clear(Remote)
      :ok = LocalOutbox.retry(head)
      drain()

      assert Enum.all?(entries(), &(&1.state == :synced))
      assert [%{name: "chain-block-2"}] = remote()
    end
  end

  # --- P6: lost-kick recovery (#4) — the sweeper actually recovers a
  # `:pending` chain head with no live job, not just "exists".

  describe "P6: the LocalOutbox sweeper recovers a lost kick" do
    defp enqueue_directly!(pk, write_ref, op, payload, base_image) do
      OutboxEntry
      |> Ash.Changeset.for_create(
        :enqueue,
        %{
          write_ref: write_ref,
          resource: Atom.to_string(Widget),
          tenant: "__global__",
          record_pk: %{"id" => pk},
          op: op,
          payload: payload,
          base_image: base_image,
          target: :remote
        },
        domain: Domain
      )
      |> Ash.create!(authorize?: false)
    end

    test "a pending entry with no live job is discovered and enqueued" do
      pk = Ash.UUID.generate()

      # Simulate the lost kick directly: the outbox row exists (as if its
      # co-commit transaction had already succeeded) but no job was ever
      # inserted for it — bypasses `Write.async_run/3`'s normal post-commit
      # `Enqueue.flush` call entirely.
      entry =
        enqueue_directly!(
          pk,
          Ash.UUID.generate(),
          :create,
          %{
            "id" => pk,
            "name" => "lost-kick",
            "count" => 0,
            "updated_at" => 0
          },
          nil
        )

      assert entry.state == :pending

      Sweeper.run_once([Widget])
      drain()

      assert [%{state: :synced}] = entries()
      assert [%{name: "lost-kick"}] = remote()
    end

    test "a same-PK chain drains fully across ticks even with no automatic kicks at all" do
      pk = Ash.UUID.generate()

      _head =
        enqueue_directly!(
          pk,
          Ash.UUID.generate(),
          :create,
          %{
            "id" => pk,
            "name" => "v1",
            "count" => 0,
            "updated_at" => 0
          },
          nil
        )

      tail =
        enqueue_directly!(
          pk,
          Ash.UUID.generate(),
          :update,
          %{"id" => pk, "name" => "v2", "count" => 0, "updated_at" => 0},
          %{"id" => pk, "name" => "v1", "count" => 0, "updated_at" => 0}
        )

      # The tail is genuinely NOT the chain head yet — the sweeper must
      # respect FIFO and not kick it out of order.
      assert Flush.chain_position(OutboxEntry, Domain, tail) == :racing

      Sweeper.run_once([Widget])
      drain()

      # Whether the head's own flush-success `kick_next` already enqueued
      # the tail or not, a second sweep tick must find and resolve it if
      # it's still stranded — the chain converges either way.
      Sweeper.run_once([Widget])
      drain()

      assert Enum.all?(entries(), &(&1.state == :synced))
      assert [%{name: "v2"}] = remote()
    end
  end

  # --- H4 (#15): a local-write failure after a successful write_through push
  # must leave a discoverable trace, never a silent ordinary failure.

  describe "H4: write_through target-push-succeeds/local-write-fails divergence" do
    test "records a parked, discoverable entry instead of silently returning an error" do
      w =
        FailableLocalWidget
        |> Ash.Changeset.for_create(:create, %{name: "to-delete"}, domain: Domain)
        |> Ash.create!()

      drain()
      assert [%{name: "to-delete"}] = remote(FailableLocalWidget)

      # The target destroy will succeed; the LOCAL destroy fails.
      FailableLayer.fail(FailableSqlite, :rejected)

      result =
        w
        |> Ash.Changeset.for_destroy(:destroy, %{}, domain: Domain)
        |> Ash.Changeset.set_context(%{multi_datalayer: %{write_through: true}})
        |> Ash.destroy()

      FailableLayer.clear(FailableSqlite)

      assert {:error, _} = result

      # Unfixed: the target already durably destroyed the row (push
      # succeeded) but nothing records this — a later refresh would pull
      # the target's now-absent row's absence into local silently, and
      # there is no trace an operator could find. Fixed: a discoverable
      # parked entry records the divergence.
      assert elem(Target.read_pk(FailableLocalWidget, :remote, %{"id" => w.id}), 1) == nil

      assert [%{state: :parked, error_class: :conflict, op: :destroy}] =
               OutboxEntry
               |> Ash.read!(domain: Domain, authorize?: false)
               |> Enum.filter(&(&1.record_pk["id"] == w.id and &1.state == :parked))
    end
  end

  # --- H3: refresh/3 propagates a local read failure instead of raising -----

  describe "H3: refresh/3 surfaces a local read failure as {:error, _}, never a raise/MatchError" do
    setup do
      FailableLayer.clear_reads(FailableSqlite)
      on_exit(fn -> FailableLayer.clear_reads(FailableSqlite) end)
      :ok
    end

    test "single-PK delete reconciliation (delete_local_pk)" do
      w =
        FailableLocalWidget
        |> Ash.Changeset.for_create(:create, %{name: "will-be-deleted-remotely"}, domain: Domain)
        |> Ash.create!()

      drain()
      Target.destroy(FailableLocalWidget, :remote, w, domain: Domain)

      # #18-sibling: pre-fix, `delete_local_pk/5`'s hard `{:ok, local_row} =`
      # match on a failing `Target.read_pk` raises instead of returning
      # `{:error, _}` — a peer's destroy notification (routed through this
      # exact single-PK `refresh/3` path) could crash the notifying process.
      FailableLayer.fail_reads(FailableSqlite, {:rejected, "local read failed"})

      assert {:error, _} = LocalOutbox.refresh(FailableLocalWidget, %{"id" => w.id})
    end

    test "the :all-scope delete reconciliation (reconcile_deletes)" do
      w =
        FailableLocalWidget
        |> Ash.Changeset.for_create(:create, %{name: "still-local"}, domain: Domain)
        |> Ash.create!()

      drain()

      # #18-sibling: pre-fix, `reconcile_deletes/5`'s hard `{:ok, local_rows} =`
      # match on a failing `Target.read_all` raises a `MatchError` instead of
      # returning `{:error, _}`.
      FailableLayer.fail_reads(FailableSqlite, {:rejected, "local read failed"})

      assert {:error, _} = LocalOutbox.refresh(FailableLocalWidget, :all)

      FailableLayer.clear_reads(FailableSqlite)
      local_ids = local(FailableLocalWidget) |> Enum.map(& &1.id)
      assert w.id in local_ids
    end
  end

  # --- M10: hydrate/2 must not wrap a failing refresh in {:ok, ...} ---------

  describe "M10: hydrate/2 propagates a failing refresh(:all) instead of wrapping it" do
    test "a failing target read surfaces as {:error, _}, not {:ok, {:error, _}}" do
      _w =
        FailableLocalWidget
        |> Ash.Changeset.for_create(:create, %{name: "hydrate-fail"}, domain: Domain)
        |> Ash.create!()

      drain()
      assert Enum.all?(entries(), &(&1.state == :synced))

      FailableLayer.fail_reads(FailableSqlite, {:rejected, "local read failed"})

      # Unfixed: `{:ok, refresh(host_resource, :all, tenant)}` — since
      # refresh/3 can itself return `{:error, reason}` (H3), this wraps it
      # into the malformed `{:ok, {:error, reason}}` — a caller pattern-
      # matching on `{:ok, stats}` treats the failure as success.
      assert {:error, _} = LocalOutbox.hydrate(FailableLocalWidget)
    after
      FailableLayer.clear_reads(FailableSqlite)
    end
  end

  # --- M1: {:upsert_skipped, ...} must not crash the LocalOutbox write path -

  describe "M1: a condition-skipped upsert through LocalOutbox does not crash" do
    setup do
      on_exit(fn -> FailableLayer.clear_skip_upsert(FailableSqlite) end)
      :ok
    end

    # A skip tuple's `callback`, when Ash core invokes it (only under
    # `return_skipped_upsert?: true`), must return the resource's OWN
    # struct, not `nil` — a plain `{:ok, nil}` stand-in trips an UNRELATED
    # `Ash.Actions.Helpers.restrict_field_access/2` clause mismatch that has
    # nothing to do with M1, so echo a plausible existing row instead.
    defp echo_callback(name),
      do: fn -> {:ok, %FailableLocalWidget{id: Ash.UUID.generate(), name: name}} end

    test "async_run surfaces the skip tuple instead of crashing in enqueue_entries" do
      FailableLayer.skip_upsert(FailableSqlite, nil, echo_callback("skip-me"))

      # Unfixed: `local_write` returns `{:ok, {:upsert_skipped, _, _}}`,
      # `async_run`'s `with {:ok, record} <- local_write(...)` binds `record`
      # to the tuple, and `enqueue_entries/7` crashes calling
      # `Snapshot.record_pk(resource, record)` — `Map.get` on a tuple.
      assert {:ok, %FailableLocalWidget{name: "skip-me"}} =
               FailableLocalWidget
               |> Ash.Changeset.for_create(:upsert_by_name, %{name: "skip-me"}, domain: Domain)
               |> Ash.create(
                 upsert?: true,
                 upsert_identity: :unique_name,
                 return_skipped_upsert?: true,
                 authorize?: false
               )
    end

    test "a skipped upsert does not enqueue an outbox entry for a write that didn't happen" do
      FailableLayer.skip_upsert(FailableSqlite, nil, echo_callback("skip-me-2"))

      FailableLocalWidget
      |> Ash.Changeset.for_create(:upsert_by_name, %{name: "skip-me-2"}, domain: Domain)
      |> Ash.create(
        upsert?: true,
        upsert_identity: :unique_name,
        return_skipped_upsert?: true,
        authorize?: false
      )

      assert OutboxEntry |> Ash.read!(domain: Domain, authorize?: false) == []
    end
  end

  # --- B7: resolution verbs on a stale handle to an already-:synced entry ----

  describe "B7: resolution verbs are idempotent no-ops on an already-:synced entry" do
    test "retry does not re-pend it" do
      _w = create!(name: "b7-retry")
      drain()
      [entry] = entries()
      assert entry.state == :synced

      # Unfixed: `ensure_resolvable_head/1` returns `:ok` for `:synced`, so
      # `retry/1` falls into its body and re-pends via the `:retry` action
      # (which has no state guard) — flipping this back to `:pending` and
      # re-flushing (re-pushing) an already-applied write.
      assert :ok = LocalOutbox.retry(entry)
      assert [%{state: :synced}] = entries()
    end

    test "force does not re-push or destroy it" do
      _w = create!(name: "b7-force")
      drain()
      [entry] = entries()
      assert entry.state == :synced

      # Unfixed: force falls into its body, blind-pushes to the target again,
      # then destroys this already-synced entry and kicks the next chain
      # entry.
      assert :ok = LocalOutbox.force(entry)
      assert [%{state: :synced}] = entries()
    end

    test "discard of a non-create entry is a no-op, not a destroy + kick_next" do
      w = create!(name: "b7-discard")
      drain()
      _updated = update!(w, name: "b7-discard-2")
      drain()

      [_create_entry, update_entry] = entries()
      assert update_entry.op == :update
      assert update_entry.state == :synced

      # Unfixed: `entry.op != :create` takes the "just this entry" branch —
      # `Ash.destroy!(entry, action: :discard, ...)` + `kick_next` — removing
      # an already-applied, already-synced entry from the outbox.
      assert {:ok, %{discarded: 0, dropped_chain: false}} = LocalOutbox.discard(update_entry)
      assert length(entries()) == 2
    end

    test "rebase does not apply the resolution changeset" do
      w = create!(name: "b7-rebase")
      drain()
      [entry] = entries()
      assert entry.state == :synced

      # Unfixed: rebase falls into its body regardless of `record_chain`
      # being `[]` (nothing parked) and applies the resolution changeset — a
      # REAL mutation the caller never should have triggered since there was
      # no conflict to resolve.
      changeset =
        w
        |> Ash.Changeset.for_update(:update, %{name: "should-not-apply"}, domain: Domain)

      assert {:ok, ^entry} = LocalOutbox.rebase(entry, changeset)
      assert [%{name: "b7-rebase"}] = local()
    end
  end

  describe "L5: sweeper {:global, ...} name collision is a clear, deliberate rejection" do
    test "a second start_link for the same resource set fails with {:already_started, _}, not a crash" do
      # `{:global, ...}` names are unique regardless of node count — even on
      # one node, a second registration attempt for the same key collides
      # exactly like a genuine peer node would. This proves start_link/1
      # surfaces that collision as a typed {:error, {:already_started, _}}
      # (logged with the single-node-only explanation) rather than letting
      # the raw OTP failure crash unexplained, or worse, silently ignoring
      # it and leaving this "node" with no supervised sweeper.
      {:ok, pid} = Sweeper.start_link(resources: [Widget])
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:already_started, ^pid}} = Sweeper.start_link(resources: [Widget])
        end)

      assert log =~ "single-node-only"
    end
  end

  # --- shared helpers ---------------------------------------------------------

  # Runs the boot_hydrate task ash_multi_datalayer registers for a resource's
  # `hydrate: :on_start | :if_empty` mode, without spinning up a real
  # supervisor — extracts the `Task.start_link/1` MFA from the child_spec and
  # awaits it directly (the same function boot would run).
  defp run_boot_hydrate!(resource) do
    spec =
      LocalOutbox.child_specs([resource])
      |> Enum.find(fn spec -> match?({_, :hydrate, ^resource}, spec.id) end)

    {Task, :start_link, [fun]} = spec.start
    Task.await(Task.async(fun))
  end

  defmodule ScratchDomain do
    @moduledoc "Domain for `define/1`'s dynamically-created, throwaway resources."
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered?(true)
    end
  end

  defp define(body) do
    module =
      :"Elixir.AshMultiDatalayer.Integration.LocalOutboxResolutionTest.R#{System.unique_integer([:positive])}"

    Module.create(
      module,
      quote do
        use Ash.Resource,
          domain: AshMultiDatalayer.Integration.LocalOutboxResolutionTest.ScratchDomain,
          data_layer: AshMultiDatalayer.DataLayer

        unquote(body)

        attributes do
          uuid_primary_key(:id)
        end
      end,
      Macro.Env.location(__ENV__)
    )

    module
  end

  defp error_message({:error, %Spark.Error.DslError{message: message}}), do: message
  defp error_message(other), do: flunk("expected {:error, %DslError{}}, got: #{inspect(other)}")
end
