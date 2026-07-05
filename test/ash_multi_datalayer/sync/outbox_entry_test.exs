defmodule AshMultiDatalayer.Sync.OutboxEntryTest do
  @moduledoc """
  Phase 3: the `AshMultiDatalayer.Sync.OutboxEntry` extension — the injected
  contract (attributes, actions, ash_oban trigger), the structural actions, the
  flush chain-head check, and the data-layer verifier.
  """
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :oban_sqlite

  alias AshMultiDatalayer.Orchestrator.LocalOutbox.Flush
  alias AshMultiDatalayer.Sync.Info, as: SyncInfo
  alias AshMultiDatalayer.Test.ObanSqlite.SkeletonRepo
  alias AshMultiDatalayer.Test.Sync.{Migrations, OutboxTestDomain, TestOutboxEntry}

  setup_all do
    db = Path.join(System.tmp_dir!(), "amd_outbox_ext_#{System.unique_integer([:positive])}.db")
    File.rm(db)
    on_exit(fn -> File.rm(db) end)

    start_supervised!({SkeletonRepo, database: db, pool_size: 1, name: SkeletonRepo})
    Ecto.Migrator.up(SkeletonRepo, 1, Migrations.OutboxTable, log: false)
    :ok
  end

  setup do
    Ecto.Adapters.SQL.query!(SkeletonRepo, "DELETE FROM amd_test_outbox", [])
    :ok
  end

  defp enqueue!(attrs) do
    defaults = %{
      resource: "TodoClient.Todo",
      record_pk: %{"id" => Ash.UUID.generate()},
      op: :update,
      target: :remote,
      write_ref: Ash.UUID.generate()
    }

    TestOutboxEntry
    |> Ash.Changeset.for_create(:enqueue, Map.merge(defaults, Map.new(attrs)),
      domain: OutboxTestDomain
    )
    |> Ash.create!(authorize?: false)
  end

  describe "injected contract" do
    test "all outbox attributes are injected" do
      names =
        TestOutboxEntry |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name) |> MapSet.new()

      expected =
        ~w(seq write_ref resource tenant record_pk op payload base_image
           remote_snapshot target state error_class last_error parked_at
           inserted_at updated_at)a

      for attr <- expected, do: assert(attr in names, "missing attribute #{attr}")

      # seq is the integer primary key.
      assert Ash.Resource.Info.primary_key(TestOutboxEntry) == [:seq]
      assert %{type: Ash.Type.Integer} = Ash.Resource.Info.attribute(TestOutboxEntry, :seq)
    end

    test "all outbox actions are injected" do
      names =
        TestOutboxEntry |> Ash.Resource.Info.actions() |> Enum.map(& &1.name) |> MapSet.new()

      for action <- ~w(enqueue flush park retry discard pending parked for_record)a do
        assert action in names, "missing action #{action}"
      end
    end

    test "the ash_oban :flush trigger is injected with the configured queue" do
      [trigger] = AshOban.Info.oban_triggers(TestOutboxEntry)
      assert trigger.name == :flush
      assert trigger.action == :flush
      assert trigger.queue == :test_outbox
      assert trigger.max_attempts == 5
      assert trigger.scheduler_cron == false
      assert trigger.worker == AshMultiDatalayer.Test.Sync.TestOutboxEntry.AshOban.Worker.Flush
    end

    test "Sync.Info exposes the outbox_entry config" do
      assert SyncInfo.queue(TestOutboxEntry) == :test_outbox
      assert SyncInfo.max_attempts(TestOutboxEntry) == 5
      assert SyncInfo.oban_instance(TestOutboxEntry) == Oban
    end
  end

  describe "structural actions" do
    test "enqueue creates a pending entry with a monotonic seq" do
      a = enqueue!(op: :create)
      b = enqueue!(op: :update)

      assert a.state == :pending
      assert is_integer(a.seq) and b.seq == a.seq + 1
      assert a.op == :create
    end

    test "park transitions pending → parked with error metadata" do
      entry = enqueue!([])

      parked =
        entry
        |> Ash.Changeset.for_update(:park, %{error_class: :rejected, last_error: %{"m" => "no"}},
          domain: OutboxTestDomain
        )
        |> Ash.update!(authorize?: false)

      assert parked.state == :parked
      assert parked.error_class == :rejected
      assert parked.parked_at != nil
    end

    test "retry restores parked → pending and clears the error" do
      entry = enqueue!([])

      parked =
        entry
        |> Ash.Changeset.for_update(:park, %{error_class: :rejected}, domain: OutboxTestDomain)
        |> Ash.update!(authorize?: false)

      retried =
        parked
        |> Ash.Changeset.for_update(:retry, %{}, domain: OutboxTestDomain)
        |> Ash.update!(authorize?: false)

      assert retried.state == :pending
      assert retried.error_class == nil
      assert retried.parked_at == nil
    end

    test "discard removes the entry" do
      entry = enqueue!([])
      Ash.destroy!(entry, action: :discard, domain: OutboxTestDomain, authorize?: false)
      assert Ash.read!(TestOutboxEntry, domain: OutboxTestDomain, authorize?: false) == []
    end

    test "pending / parked reads filter by state, sorted by seq" do
      p1 = enqueue!([])
      p2 = enqueue!([])

      parked_entry =
        enqueue!([])
        |> Ash.Changeset.for_update(:park, %{error_class: :conflict}, domain: OutboxTestDomain)
        |> Ash.update!(authorize?: false)

      pending =
        Ash.read!(TestOutboxEntry, action: :pending, domain: OutboxTestDomain, authorize?: false)

      parked =
        Ash.read!(TestOutboxEntry, action: :parked, domain: OutboxTestDomain, authorize?: false)

      assert Enum.map(pending, & &1.seq) == [p1.seq, p2.seq]
      assert Enum.map(parked, & &1.seq) == [parked_entry.seq]
    end

    test "for_record returns the chain for one (resource, record_pk, target)" do
      pk = %{"id" => Ash.UUID.generate()}
      a = enqueue!(record_pk: pk, op: :create)
      b = enqueue!(record_pk: pk, op: :update)
      _other = enqueue!(record_pk: %{"id" => Ash.UUID.generate()})

      chain =
        TestOutboxEntry
        |> Ash.Query.for_read(
          :for_record,
          %{resource: "TodoClient.Todo", record_pk: pk, target: :remote},
          domain: OutboxTestDomain
        )
        |> Ash.read!(authorize?: false)

      assert Enum.map(chain, & &1.seq) == [a.seq, b.seq]
    end
  end

  describe "flush chain-head check" do
    test "only the lowest-seq entry of a PK chain is the chain head" do
      pk = %{"id" => Ash.UUID.generate()}
      head = enqueue!(record_pk: pk, op: :create)
      tail = enqueue!(record_pk: pk, op: :update)

      assert Flush.chain_head?(TestOutboxEntry, OutboxTestDomain, head)
      refute Flush.chain_head?(TestOutboxEntry, OutboxTestDomain, tail)
    end
  end

  describe "data-layer verifier" do
    # Spark 2.7 surfaces verifier failures as compiler diagnostics, not runtime
    # raises, so exercise the verifier directly on the DSL config.
    test "rejects a non-SQL data layer" do
      module =
        :"Elixir.AshMultiDatalayer.Sync.OutboxEntryTest.EtsOutbox#{System.unique_integer([:positive])}"

      Module.create(
        module,
        quote do
          use Ash.Resource,
            domain: AshMultiDatalayer.Test.Sync.OutboxTestDomain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshMultiDatalayer.Sync.OutboxEntry]

          outbox_entry do
            queue(:bad)
          end
        end,
        Macro.Env.location(__ENV__)
      )

      assert {:error, %Spark.Error.DslError{message: message}} =
               AshMultiDatalayer.Sync.Verifiers.VerifyDataLayer.verify(module.spark_dsl_config())

      assert message =~ "requires a SQL-backed data layer"
    end

    test "passes for the SQL-backed TestOutboxEntry" do
      assert :ok =
               AshMultiDatalayer.Sync.Verifiers.VerifyDataLayer.verify(
                 TestOutboxEntry.spark_dsl_config()
               )
    end
  end
end
