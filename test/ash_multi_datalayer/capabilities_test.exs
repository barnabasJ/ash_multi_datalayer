defmodule AshMultiDatalayer.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias AshMultiDatalayer.DataLayer
  alias AshMultiDatalayer.Test.Resources.{SingleLayerPost, TestPost}

  describe "read features (intersection over read_order)" do
    test "filtering, sorting, pagination follow the read layers" do
      for feature <- [
            :read,
            :filter,
            :boolean_filter,
            :nested_expressions,
            :sort,
            :limit,
            :offset,
            :composite_primary_key
          ] do
        assert DataLayer.can?(TestPost, feature), "expected #{inspect(feature)} for TestPost"
        assert DataLayer.can?(SingleLayerPost, feature)
      end
    end

    test "select pushdown is decided by the source of truth alone" do
      # Ets can't push selects, but stripping query.select would break layers
      # (like AshRemote) that derive their fetched fields from it — the
      # source of truth decides, and select-less cache layers just return
      # full rows for Ash to narrow.
      assert DataLayer.can?(TestPost, :select)
      assert DataLayer.can?(SingleLayerPost, :select)
    end
  end

  describe "write features (intersection over write_order)" do
    test "CRUD + upsert are supported by both stacks" do
      for feature <- [:create, :update, :destroy, :upsert] do
        assert DataLayer.can?(TestPost, feature)
        assert DataLayer.can?(SingleLayerPost, feature)
      end
    end

    test "transactions require every write layer to be transactional" do
      # Ets in write_order kills :transact...
      refute DataLayer.can?(TestPost, :transact)
      # ...while a Postgres-only write_order supports it.
      assert DataLayer.can?(SingleLayerPost, :transact)
    end
  end

  describe "always-false features" do
    test "joins, combinations, and bulk/atomic query paths are rejected" do
      for feature <- [
            {:join, TestPost},
            {:lateral_join, TestPost},
            :combine,
            :update_query,
            :destroy_query,
            {:atomic, :update},
            :async_engine
          ] do
        refute DataLayer.can?(TestPost, feature), "expected NOT #{inspect(feature)}"
        refute DataLayer.can?(SingleLayerPost, feature)
      end
    end
  end

  describe "multitenancy (intersection over ALL layers)" do
    test "both stacks support it (Ets and Postgres both do)" do
      assert DataLayer.can?(TestPost, :multitenancy)
    end
  end
end
