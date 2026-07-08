defmodule AshMultiDatalayer.CoverageTest do
  # Interacts with the shared supervisor/ETS tables like TableOwnerTest.
  use ExUnit.Case, async: false

  alias AshMultiDatalayer.Coverage
  alias AshMultiDatalayer.Coverage.{Entry, TableOwner}

  defmodule FakeResource do
  end

  defmodule NoTableResource do
  end

  setup do
    on_exit(fn ->
      case GenServer.whereis(TableOwner.name(FakeResource)) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(AshMultiDatalayer.TableSupervisor, pid)
      end
    end)
  end

  defp entry(id) do
    %Entry{
      id: id,
      tenant: nil,
      filter: nil,
      normalised: %AshMultiDatalayer.Coverage.Normaliser.Normalised{disjuncts: [%{}]},
      fingerprint: 0,
      loaded_fields: MapSet.new([:id]),
      loaded_at: System.monotonic_time()
    }
  end

  test "touch/3 does not resurrect a dropped entry (M1)" do
    :ok = Coverage.ensure_table(FakeResource)
    entry = entry(make_ref())

    :ok = Coverage.insert(FakeResource, nil, entry)
    assert [_] = Coverage.entries(FakeResource, nil)

    # A concurrent write's invalidation drops the entry...
    :ok = Coverage.drop(FakeResource, nil, entry.id)
    assert Coverage.entries(FakeResource, nil) == []

    # ...and a reader's in-flight LRU touch of the (now stale) struct it
    # snapshotted before the drop must not recreate it.
    refute AshMultiDatalayer.TestSupport.touch_entry!(FakeResource, nil, entry)
    assert Coverage.entries(FakeResource, nil) == []
  end

  test "touch/3 refreshes loaded_at for a live entry" do
    :ok = Coverage.ensure_table(FakeResource)
    entry = %{entry(make_ref()) | loaded_at: 0}
    :ok = Coverage.insert(FakeResource, nil, entry)

    assert AshMultiDatalayer.TestSupport.touch_entry!(FakeResource, nil, entry)
    assert [%Entry{loaded_at: loaded_at}] = Coverage.entries(FakeResource, nil)
    refute loaded_at == 0
  end

  test "touch/3 against a resource with no table degrades instead of crashing" do
    refute Coverage.touch(NoTableResource, nil, entry(make_ref()))
  end

  test "L12 item 1: insert/3 against a resource with no table degrades instead of crashing" do
    # Unfixed: `insert/3` was the one ETS accessor with no `rescue
    # ArgumentError` — a TableOwner restart between a successful read and
    # its coverage-recording step (simulated here by a resource whose
    # table was never created) crashed the caller instead of degrading,
    # exactly like `entries/2`, `partitions/1`, and `drop/3` already do.
    assert Coverage.insert(NoTableResource, nil, entry(make_ref())) == :ok
  end
end
