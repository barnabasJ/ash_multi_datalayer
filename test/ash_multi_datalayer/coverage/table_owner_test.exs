defmodule AshMultiDatalayer.Coverage.TableOwnerTest do
  # Interacts with the shared supervisor (stops/restarts it in one test).
  use ExUnit.Case, async: false

  alias AshMultiDatalayer.Coverage
  alias AshMultiDatalayer.Coverage.TableOwner

  defmodule FakeResource do
  end

  setup do
    on_exit(fn ->
      case GenServer.whereis(TableOwner.name(FakeResource)) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(AshMultiDatalayer.TableSupervisor, pid)
      end
    end)
  end

  test "ensure_table lazily starts the owner and creates the named table" do
    table = TableOwner.table_name(FakeResource)
    assert :ets.whereis(table) == :undefined

    assert :ok = Coverage.ensure_table(FakeResource)
    assert :ets.whereis(table) != :undefined

    # Idempotent.
    assert :ok = Coverage.ensure_table(FakeResource)
  end

  test "concurrent ensure_table calls race safely to one owner" do
    results =
      1..20
      |> Task.async_stream(fn _ -> Coverage.ensure_table(FakeResource) end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &(&1 == :ok))
  end

  test "entries survive across calls and are tenant-partitioned" do
    :ok = Coverage.ensure_table(FakeResource)

    :ok = Coverage.insert(FakeResource, nil, %{id: 1, marker: :global})
    :ok = Coverage.insert(FakeResource, "org_a", %{id: 2, marker: :a})

    assert [%{marker: :global}] = Coverage.entries(FakeResource, nil)
    assert [%{marker: :a}] = Coverage.entries(FakeResource, "org_a")
    assert [] = Coverage.entries(FakeResource, "org_b")

    :ok = Coverage.drop(FakeResource, "org_a", 2)
    assert [] = Coverage.entries(FakeResource, "org_a")
  end

  test "a crashed owner is restarted with an empty ledger" do
    :ok = Coverage.ensure_table(FakeResource)
    :ok = Coverage.insert(FakeResource, nil, %{id: 1})

    pid = GenServer.whereis(TableOwner.name(FakeResource))
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    # Wait for the supervisor to restart the owner and recreate the table.
    assert :ok =
             wait_until(fn -> :ets.whereis(TableOwner.table_name(FakeResource)) != :undefined end)

    assert Coverage.entries(FakeResource, nil) == []
  end

  test "without the supervisor, ensure_table degrades instead of crashing" do
    Supervisor.stop(AshMultiDatalayer.Supervisor)

    try do
      assert {:error, :unavailable} = Coverage.ensure_table(FakeResource)
    after
      # Restore the node-global supervisor (not test-scoped: the rest of the
      # suite relies on it outliving this test).
      {:ok, pid} = AshMultiDatalayer.Supervisor.start_link()
      Process.unlink(pid)
    end
  end

  defp wait_until(fun, tries \\ 50)
  defp wait_until(_fun, 0), do: :timeout

  defp wait_until(fun, tries) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, tries - 1)
    end
  end
end
