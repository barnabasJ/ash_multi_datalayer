defmodule AshMultiDatalayer.DataCase do
  @moduledoc """
  Case template for integration tests against the Postgres TestRepo.

  Checks out an Ecto sandbox connection in shared mode (all layer work runs
  in the caller process, but shared mode keeps helpers/tasks safe), resets
  the counting-layer counters, per-resource ETS cache tables, coverage
  ledgers, and kill-switch state.
  """
  use ExUnit.CaseTemplate

  alias AshMultiDatalayer.Test.CountingLayer

  using do
    quote do
      import AshMultiDatalayer.DataCase

      alias AshMultiDatalayer.Test.CountingLayer
      alias AshMultiDatalayer.Test.Resources.{MirrorPost, SingleLayerPost, TestPost}

      @moduletag :integration
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(AshMultiDatalayer.TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(AshMultiDatalayer.TestRepo, {:shared, self()})

    CountingLayer.reset!()
    reset_resource!(AshMultiDatalayer.Test.Resources.TestPost)
    reset_resource!(AshMultiDatalayer.Test.Resources.SingleLayerPost)
    reset_resource!(AshMultiDatalayer.Test.Resources.FailingPost)
    reset_resource!(AshMultiDatalayer.Test.Resources.CappedPost)
    reset_resource!(AshMultiDatalayer.Test.Resources.SampledPost)
    reset_resource!(AshMultiDatalayer.Test.Resources.LocalEvalOffPost)
    reset_resource!(AshMultiDatalayer.Test.Resources.RaceTestPost)

    :ok
  end

  @doc """
  Clears every piece of layered state for a resource: the library's ledger +
  kill-switch via TestSupport, plus the Ets cache tables (layer-specific
  cleanup is the caller's job — the library is data-layer agnostic).
  """
  def reset_resource!(resource) do
    AshMultiDatalayer.TestSupport.reset!(resource)
    Ash.DataLayer.Ets.stop(resource)
    :ok
  end
end
