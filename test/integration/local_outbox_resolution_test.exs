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

  alias AshMultiDatalayer.Orchestrator.LocalOutbox
  alias AshMultiDatalayer.Orchestrator.LocalOutbox.{Flush, Target}
  alias AshMultiDatalayer.Test.FailableLayer

  alias AshMultiDatalayer.Test.LocalOutbox.{
    Domain,
    FailableLocalWidget,
    FailableSqlite,
    FailableTarget,
    IfEmptyWidget,
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
    for t <- ~w(lo_widgets lo_timestamp_widgets lo_ifempty_widgets lo_failable_local_widgets lo_outbox oban_jobs) do
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

      changeset = Ash.Changeset.for_update(w, :update, %{name: "resolved", count: 99}, domain: Domain)
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
                 outbox_resource: AshMultiDatalayer.Test.LocalOutbox.OutboxEntry,
                 hydrate: :manual}
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

  # --- shared helpers ---------------------------------------------------------

  # Runs the boot_hydrate task ash_multi_datalayer registers for a resource's
  # `hydrate: :on_start | :if_empty` mode, without spinning up a real
  # supervisor — extracts the `Task.start_link/1` MFA from the child_spec and
  # awaits it directly (the same function boot would run).
  defp run_boot_hydrate!(resource) do
    [spec] = LocalOutbox.child_specs([resource])
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
    module = :"Elixir.AshMultiDatalayer.Integration.LocalOutboxResolutionTest.R#{System.unique_integer([:positive])}"

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
