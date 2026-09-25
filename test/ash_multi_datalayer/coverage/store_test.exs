defmodule AshMultiDatalayer.Coverage.StoreTest do
  @moduledoc """
  `AshMultiDatalayer.Coverage.Store`: the optional write-through/restore layer
  behind a resource's `coverage_store:` option. Unit-level tests build `Entry`
  structs directly and drive `Store`'s async functions, synchronizing on the
  spawned task via `Process.monitor/1` (the task pid each async function
  returns is a deliberate test seam — see `persist_async/3`'s doc). The final
  describe block proves the whole path end to end through a real
  `AshMultiDatalayer.Orchestrator.ProvenCoverage` read.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias AshMultiDatalayer.Coverage
  alias AshMultiDatalayer.Coverage.{Entry, Normaliser, Store, TableOwner}
  alias AshMultiDatalayer.Test.Coverage.{CoverageStoreResource, CoverageTestDomain, TestStoreEntry}

  setup do
    TestStoreEntry
    |> Ash.Query.for_read(:read, %{}, domain: CoverageTestDomain)
    |> Ash.bulk_destroy!(:destroy, %{}, authorize?: false, return_errors?: false)

    on_exit(fn ->
      case GenServer.whereis(TableOwner.name(CoverageStoreResource)) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(AshMultiDatalayer.TableSupervisor, pid)
      end
    end)

    :ok
  end

  defp entry(fingerprint, loaded_fields \\ [:id, :name]) do
    %Entry{
      id: make_ref(),
      tenant: nil,
      filter: nil,
      normalised: %Normaliser.Normalised{disjuncts: [%{}]},
      fingerprint: fingerprint,
      loaded_fields: MapSet.new(loaded_fields),
      loaded_at: DateTime.utc_now()
    }
  end

  # Awaits an async Store call's task so assertions run only after its write
  # lands — no sleep/poll, a deterministic seam via the returned pid.
  defp await!({:ok, pid}) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1000
  end

  defp await!(:ok), do: flunk("expected {:ok, pid} — coverage_store was not configured")

  defp stored_rows(resource) do
    TestStoreEntry
    |> Ash.Query.for_read(:read, %{}, domain: CoverageTestDomain)
    |> Ash.Query.filter(resource == ^Atom.to_string(resource))
    |> Ash.read!(authorize?: false)
  end

  describe "configured?/1" do
    test "true for a resource with coverage_store: set" do
      assert Store.configured?(CoverageStoreResource)
    end

    test "false for a multi_data_layer resource without coverage_store:" do
      refute Store.configured?(AshMultiDatalayer.Test.Resources.EtsPost)
    end

    test "false (never raises) for a module with no Spark DSL at all" do
      refute Store.configured?(NotASparkModuleAtAll)
    end
  end

  describe "persist_async/3" do
    test "upserts entry into the configured store" do
      await!(Store.persist_async(CoverageStoreResource, nil, entry(1)))

      assert [row] = stored_rows(CoverageStoreResource)
      assert row.fingerprint == 1
      assert Enum.sort(row.loaded_fields) == ["id", "name"]
      assert :erlang.binary_to_term(row.tenant) == nil
    end

    test "widening (same fingerprint, wider loaded_fields) upserts in place" do
      await!(Store.persist_async(CoverageStoreResource, nil, entry(2, [:id])))
      await!(Store.persist_async(CoverageStoreResource, nil, entry(2, [:id, :name, :age])))

      assert [row] = stored_rows(CoverageStoreResource)
      assert Enum.sort(row.loaded_fields) == ["age", "id", "name"]
    end

    test "no-ops (returns :ok, writes nothing) when unconfigured" do
      assert Store.persist_async(AshMultiDatalayer.Test.Resources.EtsPost, nil, entry(1)) == :ok
      assert stored_rows(AshMultiDatalayer.Test.Resources.EtsPost) == []
    end
  end

  describe "delete_async/3" do
    test "removes only the matching (resource, tenant, fingerprint) row" do
      await!(Store.persist_async(CoverageStoreResource, nil, entry(1)))
      await!(Store.persist_async(CoverageStoreResource, nil, entry(2)))

      await!(Store.delete_async(CoverageStoreResource, nil, entry(1)))

      assert [row] = stored_rows(CoverageStoreResource)
      assert row.fingerprint == 2
    end

    test "a missing row is a no-op" do
      await!(Store.delete_async(CoverageStoreResource, nil, entry(999)))
      assert stored_rows(CoverageStoreResource) == []
    end
  end

  describe "clear_resource_async/1" do
    test "removes every row for the resource, across tenants, leaving others untouched" do
      await!(Store.persist_async(CoverageStoreResource, "tenant-a", entry(1)))
      await!(Store.persist_async(CoverageStoreResource, "tenant-b", entry(2)))

      # CappedPost has no coverage_store: configured — persist it directly
      # against TestStoreEntry to prove clear_resource_async/1 scopes by the
      # `resource` column, not "everything in the table".
      Ash.Changeset.for_create(
        TestStoreEntry,
        :record,
        %{
          resource: Atom.to_string(AshMultiDatalayer.Test.Resources.CappedPost),
          tenant: :erlang.term_to_binary(nil),
          fingerprint: 3,
          normalised: :erlang.term_to_binary(%Normaliser.Normalised{disjuncts: [%{}]}),
          filter: :erlang.term_to_binary(nil),
          loaded_fields: ["id"],
          loaded_at: DateTime.utc_now()
        },
        domain: CoverageTestDomain
      )
      |> Ash.create!(authorize?: false)

      await!(Store.clear_resource_async(CoverageStoreResource))

      assert stored_rows(CoverageStoreResource) == []
      assert [%{fingerprint: 3}] = stored_rows(AshMultiDatalayer.Test.Resources.CappedPost)
    end
  end

  describe "restore/1" do
    test "repopulates the ETS ledger from persisted rows, across tenants" do
      await!(Store.persist_async(CoverageStoreResource, "tenant-a", entry(1, [:id])))
      await!(Store.persist_async(CoverageStoreResource, "tenant-b", entry(2, [:id, :name])))

      # Simulate a BEAM restart: kill the table owner (its ETS table dies
      # with it), leaving the persisted store as the only surviving copy.
      # `ensure_table/1` first, since neither `persist_async/3` (writes only
      # to the coverage_store, never the ETS ledger) nor a plain `entries/2`
      # call starts the table owner — without this the table owner was
      # never started and `GenServer.whereis/1` below returns `nil`.
      :ok = Coverage.ensure_table(CoverageStoreResource)
      pid = GenServer.whereis(TableOwner.name(CoverageStoreResource))
      :ok = DynamicSupervisor.terminate_child(AshMultiDatalayer.TableSupervisor, pid)
      assert Coverage.entries(CoverageStoreResource, "tenant-a") == []

      assert :ok = Store.restore(CoverageStoreResource)

      assert [restored_a] = Coverage.entries(CoverageStoreResource, "tenant-a")
      assert restored_a.fingerprint == 1
      assert restored_a.loaded_fields == MapSet.new([:id])
      assert restored_a.tenant == "tenant-a"

      assert [restored_b] = Coverage.entries(CoverageStoreResource, "tenant-b")
      assert restored_b.fingerprint == 2
      assert restored_b.loaded_fields == MapSet.new([:id, :name])
    end

    test "a restored entry gets a fresh ETS-local id, not the persisted row's id" do
      original = entry(1)
      await!(Store.persist_async(CoverageStoreResource, nil, original))

      :ok = Coverage.ensure_table(CoverageStoreResource)
      pid = GenServer.whereis(TableOwner.name(CoverageStoreResource))
      :ok = DynamicSupervisor.terminate_child(AshMultiDatalayer.TableSupervisor, pid)
      :ok = Store.restore(CoverageStoreResource)

      assert [restored] = Coverage.entries(CoverageStoreResource, nil)
      assert restored.id != original.id
      assert is_reference(restored.id)
    end

    test "no-ops when unconfigured" do
      assert Store.restore(AshMultiDatalayer.Test.Resources.EtsPost) == :ok
    end
  end

  describe "end to end through a real ProvenCoverage read" do
    test "a real read records coverage, persists it, and survives a simulated restart" do
      %{id: id} =
        CoverageStoreResource
        |> Ash.Changeset.for_create(:create, %{name: "alice"}, domain: CoverageTestDomain)
        |> Ash.create!()

      # Warm the ledger via a real, recordable read.
      CoverageStoreResource
      |> Ash.Query.for_read(:read, %{}, domain: CoverageTestDomain)
      |> Ash.Query.filter(id == ^id)
      |> Ash.read!()

      assert [_entry] = Coverage.entries(CoverageStoreResource, nil)

      # The write-through is async — wait for it to land by polling the
      # store directly (no task pid is exposed on this path; it runs inside
      # the read pipeline, not a directly-called Store function).
      assert wait_until(fn -> stored_rows(CoverageStoreResource) != [] end)

      # Simulate a restart: kill the table owner, then restore from the
      # persisted row instead of the (now-empty) in-memory ledger.
      pid = GenServer.whereis(TableOwner.name(CoverageStoreResource))
      :ok = DynamicSupervisor.terminate_child(AshMultiDatalayer.TableSupervisor, pid)
      assert Coverage.entries(CoverageStoreResource, nil) == []

      assert :ok = Store.restore(CoverageStoreResource)
      assert [restored] = Coverage.entries(CoverageStoreResource, nil)
      assert MapSet.member?(restored.loaded_fields, :id)
    end

    test "ProvenCoverage.child_specs/1's returned spec performs the restore when started" do
      %{id: id} =
        CoverageStoreResource
        |> Ash.Changeset.for_create(:create, %{name: "bob"}, domain: CoverageTestDomain)
        |> Ash.create!()

      CoverageStoreResource
      |> Ash.Query.for_read(:read, %{}, domain: CoverageTestDomain)
      |> Ash.Query.filter(id == ^id)
      |> Ash.read!()

      assert [_entry] = Coverage.entries(CoverageStoreResource, nil)
      assert wait_until(fn -> stored_rows(CoverageStoreResource) != [] end)

      pid = GenServer.whereis(TableOwner.name(CoverageStoreResource))
      :ok = DynamicSupervisor.terminate_child(AshMultiDatalayer.TableSupervisor, pid)
      assert Coverage.entries(CoverageStoreResource, nil) == []

      [spec] = AshMultiDatalayer.Orchestrator.ProvenCoverage.child_specs([CoverageStoreResource])
      {:ok, sup} = Supervisor.start_link([spec], strategy: :one_for_one)
      on_exit(fn -> if Process.alive?(sup), do: Supervisor.stop(sup) end)

      assert wait_until(fn -> Coverage.entries(CoverageStoreResource, nil) != [] end)
    end
  end

  defp wait_until(fun, attempts \\ 50) do
    cond do
      fun.() -> true
      attempts <= 0 -> false
      true -> (Process.sleep(10); wait_until(fun, attempts - 1))
    end
  end
end
