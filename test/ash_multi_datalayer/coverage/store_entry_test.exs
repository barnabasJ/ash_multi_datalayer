defmodule AshMultiDatalayer.Coverage.StoreEntryTest do
  @moduledoc """
  The `AshMultiDatalayer.Coverage.StoreEntry` extension: the injected contract
  (attributes, identity, actions) that `AshMultiDatalayer.Coverage.Store` relies
  on, and the `:record` action's upsert-on-identity behaviour.
  """
  # TestStoreEntry's Ets table is deliberately non-private (see its
  # moduledoc) — a genuinely shared table across processes, so tests clear
  # it between runs instead of relying on per-process isolation.
  use ExUnit.Case, async: false

  require Ash.Query

  alias AshMultiDatalayer.Test.Coverage.{CoverageTestDomain, TestStoreEntry}

  setup do
    TestStoreEntry
    |> Ash.Query.for_read(:read, %{}, domain: CoverageTestDomain)
    |> Ash.bulk_destroy!(:destroy, %{}, authorize?: false, return_errors?: false)

    :ok
  end

  defp record!(attrs) do
    defaults = %{
      resource: "MyApp.Todo",
      tenant: :erlang.term_to_binary(nil),
      fingerprint: 0,
      normalised: :erlang.term_to_binary(%{disjuncts: [%{}]}),
      filter: :erlang.term_to_binary(nil),
      loaded_fields: ["id"],
      loaded_at: DateTime.utc_now()
    }

    TestStoreEntry
    |> Ash.Changeset.for_create(:record, Map.merge(defaults, Map.new(attrs)),
      domain: CoverageTestDomain
    )
    |> Ash.create!(authorize?: false)
  end

  describe "injected contract" do
    test "all coverage-store attributes are injected" do
      names =
        TestStoreEntry |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name) |> MapSet.new()

      expected =
        ~w(id resource tenant fingerprint normalised filter loaded_fields loaded_at
           inserted_at updated_at)a

      for attr <- expected, do: assert(attr in names, "missing attribute #{attr}")
    end

    test "all coverage-store actions are injected" do
      names = TestStoreEntry |> Ash.Resource.Info.actions() |> Enum.map(& &1.name) |> MapSet.new()

      for action <- ~w(record read destroy)a do
        assert action in names, "missing action #{action}"
      end
    end

    test "the coverage_entry identity is injected on (resource, tenant, fingerprint)" do
      assert [%{name: :coverage_entry, keys: keys}] = Ash.Resource.Info.identities(TestStoreEntry)
      assert MapSet.new(keys) == MapSet.new([:resource, :tenant, :fingerprint])
    end
  end

  describe ":record action" do
    test "creates a new row" do
      entry = record!([])
      assert entry.resource == "MyApp.Todo"
      assert entry.fingerprint == 0
    end

    test "upserts in place on (resource, tenant, fingerprint) instead of duplicating" do
      record!(fingerprint: 1, loaded_fields: ["id"])
      record!(fingerprint: 1, loaded_fields: ["id", "name"])

      rows =
        TestStoreEntry
        |> Ash.Query.for_read(:read, %{}, domain: CoverageTestDomain)
        |> Ash.Query.filter(fingerprint == 1)
        |> Ash.read!(authorize?: false)

      assert [row] = rows
      assert Enum.sort(row.loaded_fields) == ["id", "name"]
    end

    test "a distinct fingerprint does not collide with an existing row" do
      record!(fingerprint: 10)
      record!(fingerprint: 20)

      rows = Ash.read!(TestStoreEntry, domain: CoverageTestDomain, authorize?: false)
      assert length(rows) == 2
    end
  end
end
