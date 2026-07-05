defmodule Mix.Tasks.AshMultiDatalayer.Gen.OutboxTest do
  @moduledoc """
  Phase 3: the `ash_multi_datalayer.gen.outbox` + `ash_multi_datalayer.install`
  igniter generators — files created, Oban Lite config emitted, idempotent
  re-runs. (The generated resource's runtime behaviour — repo boots, Oban Lite
  job round-trips, injected actions — is covered by the OutboxEntry extension
  test + the Phase 2 skeleton, which use a resource of the exact generated shape.)
  """
  use ExUnit.Case, async: false
  import Igniter.Test

  @argv ["MyApp.Sync.OutboxEntry", "--repo", "MyApp.Repo", "--queue", "todo_sync"]

  describe "gen.outbox" do
    setup do
      %{igniter: test_project() |> Igniter.compose_task("ash_multi_datalayer.gen.outbox", @argv)}
    end

    test "creates the sync domain", %{igniter: igniter} do
      assert_creates(igniter, "lib/my_app/sync.ex", fn content ->
        assert content =~ "use Ash.Domain"
        content
      end)
    end

    test "creates the outbox entry resource of the generated shape", %{igniter: igniter} do
      assert_creates(igniter, "lib/my_app/sync/outbox_entry.ex", fn content ->
        assert content =~ "extensions: [AshMultiDatalayer.Sync.OutboxEntry]"
        assert content =~ "data_layer: AshSqlite.DataLayer"
        assert content =~ "outbox_entry do"
        assert content =~ "queue(:todo_sync)"
        assert content =~ "repo(MyApp.Repo)"
        assert content =~ "table(\"amd_outbox_entries\")"
        content
      end)
    end

    test "configures the Oban Lite engine + queue", %{igniter: igniter} do
      assert_creates(igniter, "config/config.exs", fn content ->
        assert content =~ "Oban.Engines.Lite"
        assert content =~ "todo_sync"
        content
      end)
    end

    test "prints the orchestrator DSL snippet to paste", %{igniter: igniter} do
      notice = Enum.join(igniter.notices, "\n")
      assert notice =~ "AshMultiDatalayer.Orchestrator.LocalOutbox"
      assert notice =~ "outbox_resource: MyApp.Sync.OutboxEntry"
    end

    test "declares ash_sqlite + ash_oban installs in info/2" do
      info = Mix.Tasks.AshMultiDatalayer.Gen.Outbox.info([], nil)
      install_names = Enum.map(info.installs, &elem(&1, 0))
      assert :ash_sqlite in install_names
      assert :ash_oban in install_names
    end

    test "is idempotent — a second run makes no further changes" do
      first =
        test_project()
        |> Igniter.compose_task("ash_multi_datalayer.gen.outbox", @argv)
        |> apply_igniter!()

      first
      |> Igniter.compose_task("ash_multi_datalayer.gen.outbox", @argv)
      |> assert_unchanged()
    end
  end

  describe "install" do
    test "adds the supervisor to the application tree" do
      igniter =
        test_project()
        |> Igniter.compose_task("ash_multi_datalayer.install", [])

      assert_creates(igniter, "lib/test/application.ex", fn content ->
        assert content =~ "AshMultiDatalayer.Supervisor"
        assert content =~ "otp_app: :test"
        content
      end)
    end
  end
end
