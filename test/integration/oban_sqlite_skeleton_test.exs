defmodule AshMultiDatalayer.Integration.ObanSqliteSkeletonTest do
  @moduledoc """
  Phase 2 walking skeleton: one thin vertical slice — an `AshSqlite` resource
  with an `AshOban` `:flush` trigger, executed by Oban's `Lite` engine over
  SQLite files — that de-risks every third-party assumption the LocalOutbox
  strategy builds on. Each `describe` block is one numbered plan item; the
  recorded answers live in the plan's Phase 2 Addendum.

  Runs opt-in (`:oban_sqlite` tag) and synchronously (SQLite is single-writer).
  """
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :oban_sqlite

  alias AshMultiDatalayer.Test.ObanSqlite.{
    Entry,
    Migrations,
    Probe,
    SkeletonDomain,
    SkeletonRepo,
    SkeletonRepoB
  }

  @default_oban Oban
  @instance_b AshMultiDatalayer.Test.ObanSqlite.ObanB
  @queue :skeleton_flush

  setup_all do
    Probe.ensure!()

    tmp = fn tag ->
      Path.join(
        System.tmp_dir!(),
        "amd_oban_sqlite_#{tag}_#{System.unique_integer([:positive])}.db"
      )
    end

    db_a = tmp.("a")
    db_b = tmp.("b")
    File.rm(db_a)
    File.rm(db_b)

    on_exit(fn ->
      File.rm(db_a)
      File.rm(db_b)
    end)

    # A: the resource file (entry table + Oban Lite). B: a *separate* file with
    # only its own oban_jobs, so instance B is genuinely isolated from A.
    start_supervised!({SkeletonRepo, database: db_a, pool_size: 1, name: SkeletonRepo},
      id: :repo_a
    )

    start_supervised!({SkeletonRepoB, database: db_b, pool_size: 1, name: SkeletonRepoB},
      id: :repo_b
    )

    Ecto.Migrator.up(SkeletonRepo, 1, Migrations.EntryTable, log: false)
    Ecto.Migrator.up(SkeletonRepo, 2, Migrations.ObanJobsTable, log: false)
    Ecto.Migrator.up(SkeletonRepoB, 1, Migrations.ObanJobsTable, log: false)

    oban_opts = fn name, repo ->
      [
        name: name,
        engine: Oban.Engines.Lite,
        repo: repo,
        testing: :manual,
        queues: [{@queue, 5}],
        plugins: [{Oban.Plugins.Cron, crontab: []}]
      ]
    end

    start_supervised!({Oban, oban_opts.(@default_oban, SkeletonRepo)}, id: :oban_a)
    start_supervised!({Oban, oban_opts.(@instance_b, SkeletonRepoB)}, id: :oban_b)

    :ok
  end

  setup do
    Ecto.Adapters.SQL.query!(SkeletonRepo, "DELETE FROM amd_skeleton_entries", [])
    Ecto.Adapters.SQL.query!(SkeletonRepo, "DELETE FROM oban_jobs", [])
    Ecto.Adapters.SQL.query!(SkeletonRepoB, "DELETE FROM oban_jobs", [])
    Probe.reset!()
    :ok
  end

  # --- helpers -----------------------------------------------------------

  defp enqueue!(attrs) do
    attrs = Map.merge(%{ref: Ash.UUID.generate()}, Map.new(attrs))

    Entry
    |> Ash.Changeset.for_create(:enqueue, attrs, domain: SkeletonDomain)
    |> Ash.create!(authorize?: false)
  end

  # MDL-owned insertion: build a job from ash_oban's generated worker and insert
  # it into a *chosen* instance (ash_oban's own paths always hit the default).
  defp mdl_insert(instance, entry) do
    args = %{"primary_key" => %{"seq" => entry.seq}}
    {:ok, job} = Oban.insert(instance, Entry.FlushWorker.new(args))
    job
  end

  defp drain(instance, opts \\ []) do
    Oban.drain_queue(instance, Keyword.merge([queue: @queue], opts))
  end

  defp reload(entry),
    do: Ash.get(Entry, %{seq: entry.seq}, domain: SkeletonDomain, authorize?: false)

  defp job_count do
    %{rows: [[n]]} = Ecto.Adapters.SQL.query!(SkeletonRepo, "SELECT count(*) FROM oban_jobs", [])
    n
  end

  defp job_row(repo, job_id) do
    %{columns: cols, rows: [row]} =
      Ecto.Adapters.SQL.query!(repo, "SELECT * FROM oban_jobs WHERE id = $1", [job_id])

    cols |> Enum.zip(row) |> Map.new()
  end

  defp park!(entry) do
    entry
    |> Ash.Changeset.for_update(:park, %{error_class: :rejected}, domain: SkeletonDomain)
    |> Ash.update!(authorize?: false)
  end

  # --- item 1: ash_sqlite resource + codegen (ash 3.29 compat) -----------

  describe "item 1 — ash_sqlite resource + migration codegen" do
    test "CRUD round-trips through Ash on ecto_sqlite3" do
      created = enqueue!(name: "widget", payload: %{"a" => 1})
      assert created.name == "widget"

      assert {:ok, fetched} = reload(created)
      assert fetched.ref == created.ref

      fetched
      |> Ash.Changeset.for_update(:update, %{name: "renamed"}, domain: SkeletonDomain)
      |> Ash.update!(authorize?: false)

      assert {:ok, %{name: "renamed"}} = reload(created)
    end

    test "migration generator emits SQLite DDL for the resource (codegen works)" do
      snapshot_path =
        Path.join(System.tmp_dir!(), "amd_skeleton_snap_#{System.unique_integer([:positive])}")

      prev = Mix.shell()
      Mix.shell(Mix.Shell.Process)

      try do
        AshSqlite.MigrationGenerator.generate(SkeletonDomain,
          snapshot_path: snapshot_path,
          migration_path: snapshot_path,
          dry_run: true,
          name: "skeleton_probe"
        )
      after
        Mix.shell(prev)
        File.rm_rf(snapshot_path)
      end

      output =
        receive do
          {:mix_shell, :info, [msg]} -> msg
        after
          0 -> ""
        end

      assert output =~ "amd_skeleton_entries"
      assert output =~ "create table"
    end
  end

  # --- item 9: seq autoincrement on SQLite -------------------------------

  describe "item 9 — seq (INTEGER PRIMARY KEY) autoincrements" do
    test "seq is a monotonic integer PK; ref is a separate uuid identity" do
      a = enqueue!(name: "a")
      b = enqueue!(name: "b")
      c = enqueue!(name: "c")

      assert is_integer(a.seq) and is_integer(b.seq) and is_integer(c.seq)
      assert b.seq == a.seq + 1
      assert c.seq == b.seq + 1

      # ref is a distinct uuid identity, not the ordering key.
      assert a.ref != b.ref

      assert {:ok, fetched} =
               Ash.get(Entry, %{ref: a.ref}, domain: SkeletonDomain, authorize?: false)

      assert fetched.seq == a.seq
    end
  end

  # --- item 10: payload round-trip via a :map attribute ------------------

  describe "item 10 — record snapshot round-trips through a :map attribute" do
    test "a dumped-map payload survives the SQLite JSON round-trip" do
      snapshot = %{
        "title" => "Buy milk",
        "count" => 3,
        "done" => false,
        "tags" => ["home", "urgent"],
        "nested" => %{"x" => 1}
      }

      created = enqueue!(payload: snapshot, base_image: %{"title" => "old"})
      assert {:ok, fetched} = reload(created)
      assert fetched.payload == snapshot
      assert fetched.base_image == %{"title" => "old"}
    end
  end

  # --- item 8: co-commit despite can?(:transact) == false ----------------

  describe "item 8 — co-commit via raw Repo.transaction (not can?(:transact))" do
    test "ash_sqlite hardcodes can?(:transact) == false" do
      refute AshSqlite.DataLayer.can?(Entry, :transact)
    end

    test "two Ash writes commit atomically inside one Repo.transaction" do
      {:ok, _} =
        SkeletonRepo.transaction(fn ->
          enqueue!(name: "co-a")
          enqueue!(name: "co-b")
        end)

      assert length(Ash.read!(Entry, domain: SkeletonDomain, authorize?: false)) == 2
    end

    test "a raise inside the transaction rolls both writes back" do
      assert_raise RuntimeError, fn ->
        SkeletonRepo.transaction(fn ->
          enqueue!(name: "rollback-a")
          raise "boom before the second write commits"
        end)
      end

      assert Ash.read!(Entry, domain: SkeletonDomain, authorize?: false) == []
    end
  end

  # --- item 2: trigger fires the flush action ----------------------------

  describe "item 2 — trigger fires the flush action" do
    test "AshOban.run_trigger enqueues + drain runs the flush action" do
      entry = enqueue!(name: "run-trigger", behavior: :ok)
      AshOban.run_trigger(entry, :flush)

      assert %{success: 1} = drain(@default_oban)
      # behavior :ok deletes the entry on success.
      assert {:error, _} = reload(entry)
      assert Probe.runs(entry.ref) == 1
    end

    test "an MDL sweep of the `:pending` read enqueues only pending entries" do
      # scheduler_cron false → no ash_oban scheduler is generated; the sweep is
      # MDL-owned: read pending entries (the read action's `where`/sort) and
      # insert a flush job per row. A parked entry is excluded by the filter.
      pending = enqueue!(name: "p", behavior: :ok)
      _parked = enqueue!(name: "done", behavior: :ok) |> park!()

      for entry <- Ash.read!(Entry, action: :pending, domain: SkeletonDomain, authorize?: false) do
        mdl_insert(@default_oban, entry)
      end

      assert %{success: 1} = drain(@default_oban)
      assert Probe.runs(pending.ref) == 1
    end
  end

  # --- item 3: park paths (rejection immediate; transient exhaustion) ----

  describe "item 3 — parking" do
    test "a rejection parks immediately and completes the job (no retries)" do
      entry = enqueue!(name: "reject", behavior: :reject)
      AshOban.run_trigger(entry, :flush)

      assert %{success: 1, failure: 0} = drain(@default_oban)
      assert {:ok, %{state: :parked, error_class: :rejected}} = reload(entry)
      assert Probe.runs(entry.ref) == 1
    end

    test "transient failures retry to max_attempts, then the action self-parks" do
      # Finding: ash_oban's `on_error` does NOT fire for generic-action triggers,
      # so the flush action self-parks at its last attempt.
      entry = enqueue!(name: "transient", behavior: :transient)
      AshOban.run_trigger(entry, :flush)

      Enum.each(1..6, fn _ -> drain(@default_oban, with_scheduled: true, with_recursion: true) end)

      assert {:ok, %{state: :parked, error_class: :transient_exhausted}} = reload(entry)
      assert Probe.runs(entry.ref) >= 3
    end
  end

  # --- item 4: pause/resume under Lite -----------------------------------

  describe "item 4 — pause/resume accumulates then drains" do
    test "a paused queue accumulates; resume + drain runs them" do
      :ok = Oban.pause_queue(@default_oban, queue: @queue)

      e1 = enqueue!(name: "pz1", behavior: :ok)
      e2 = enqueue!(name: "pz2", behavior: :ok)
      AshOban.run_trigger(e1, :flush)
      AshOban.run_trigger(e2, :flush)

      assert Probe.runs(e1.ref) == 0

      :ok = Oban.resume_queue(@default_oban, queue: @queue)
      assert %{success: 2} = drain(@default_oban)
      assert Probe.runs(e1.ref) == 1 and Probe.runs(e2.ref) == 1
    end
  end

  # --- item 5: snooze = zero budget burn ---------------------------------

  describe "item 5 — SnoozeJob reschedules with zero retry-budget burn" do
    test "snooze increments max_attempts (attempt not consumed)" do
      entry = enqueue!(name: "snooze", behavior: :snooze)
      %{id: job_id} = mdl_insert(@default_oban, entry)

      before = job_row(SkeletonRepo, job_id)
      assert %{snoozed: 1} = drain(@default_oban, with_scheduled: false)
      after_snooze = job_row(SkeletonRepo, job_id)

      assert after_snooze["max_attempts"] > before["max_attempts"]
      assert after_snooze["state"] in ["scheduled", "available"]
    end
  end

  # --- item 6: unique-job dedup on Lite ----------------------------------

  describe "item 6 — unique jobs dedup on the Lite engine" do
    test "two identical flush jobs for one entry dedup to a single job" do
      entry = enqueue!(name: "uniq", behavior: :ok)

      j1 = mdl_insert(@default_oban, entry)
      j2 = mdl_insert(@default_oban, entry)

      assert j1.id == j2.id
      assert job_count() == 1
    end
  end

  # --- item 7: keyset streaming (the sweep/scheduler mechanism) ----------

  describe "item 7 — keyset pagination streams pending entries in order" do
    test "the :pending read action paginates by keyset on ash_sqlite" do
      e1 = enqueue!(name: "k1")
      e2 = enqueue!(name: "k2")
      e3 = enqueue!(name: "k3")

      page1 =
        Ash.read!(Entry,
          action: :pending,
          page: [limit: 2],
          domain: SkeletonDomain,
          authorize?: false
        )

      assert Enum.map(page1.results, & &1.seq) == [e1.seq, e2.seq]

      page2 = Ash.page!(page1, :next)
      assert Enum.map(page2.results, & &1.seq) == [e3.seq]
    end
  end

  # --- item 11: named-instance routing (the R1 mechanism, two files) -----

  describe "item 11 — named Oban instance routing (isolated files)" do
    test "MDL-owned insertion into B runs under B; job.conf.name == B" do
      entry = enqueue!(name: "to-b", behavior: :ok)
      mdl_insert(@instance_b, entry)

      assert %{success: 1} = drain(@instance_b)
      assert Probe.instance(entry.ref) == @instance_b
      assert {:error, _} = reload(entry)
    end

    test "AshOban.run_trigger lands in the default instance, never B (the R1 gap)" do
      entry = enqueue!(name: "default-only", behavior: :ok)
      AshOban.run_trigger(entry, :flush)

      # B's separate file has no such job.
      assert %{success: 0} = drain(@instance_b)
      assert Probe.runs(entry.ref) == 0
      # The default instance (A's file) has it.
      assert %{success: 1} = drain(@default_oban)
      assert Probe.instance(entry.ref) == @default_oban
    end

    test "unique dedup holds under MDL-owned insertion into B" do
      entry = enqueue!(name: "uniq-b", behavior: :ok)
      j1 = mdl_insert(@instance_b, entry)
      j2 = mdl_insert(@instance_b, entry)

      assert j1.id == j2.id
      assert %{success: 1} = drain(@instance_b)
      assert Probe.runs(entry.ref) == 1
    end
  end
end
