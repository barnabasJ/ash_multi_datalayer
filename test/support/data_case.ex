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

    :ok
  end

  @doc """
  Clears every piece of layered state for a resource: the ETS cache tables,
  the coverage ledger, and the kill-switch.
  """
  def reset_resource!(resource) do
    Ash.DataLayer.Ets.stop(resource)
    AshMultiDatalayer.Coverage.reset(resource)
    AshMultiDatalayer.enable!(resource)
    :ok
  end
end
