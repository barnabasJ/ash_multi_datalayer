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

    test "transactions follow the write AUTHORITY (Phase 4a), matching transaction/4" do
      # Phase 4a: `:transact` is authority-only, not the write-order intersection —
      # `transaction/4` already delegates to the write authority (hd write_order)
      # alone, so the honest answer is the authority's. TestPost's authority is
      # Postgres → transactions ARE supported (the old intersection said false only
      # because Ets is also in write_order, which is inconsistent with what
      # transaction/4 actually does).
      assert DataLayer.can?(TestPost, :transact)
      assert DataLayer.can?(SingleLayerPost, :transact)
    end
  end

  describe "authority-only + refusal features (Phase 4a)" do
    test "locking follows the read authority (resurrected lock path, N10)" do
      # TestPost's read authority (last read_order layer) is Postgres, which
      # supports FOR UPDATE — a locked read routes to the source and is served.
      assert DataLayer.can?(TestPost, {:lock, :for_update})
      assert DataLayer.can?(SingleLayerPost, {:lock, :for_update})
    end

    test "aggregate_filter / aggregate_sort are refused loudly (M3)" do
      # Filtering/sorting on a foldable aggregate would crash with
      # KeyError __ash_bindings__; refuse explicitly instead.
      refute DataLayer.can?(TestPost, :aggregate_filter)
      refute DataLayer.can?(TestPost, :aggregate_sort)
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
