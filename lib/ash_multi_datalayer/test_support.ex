defmodule AshMultiDatalayer.TestSupport do
  @moduledoc """
  Helpers for host applications' test suites.

      setup do
        AshMultiDatalayer.TestSupport.reset!(MyApp.Post)
        :ok
      end

  `reset!/1` clears every piece of node-local layered state for a resource:
  the coverage ledger, the kill-switch, and any `Ash.DataLayer.Ets` layer
  tables — so each test starts cold and enabled.
  """

  alias AshMultiDatalayer.Coverage
  alias AshMultiDatalayer.KillSwitch

  @doc "Clears ledger, kill-switch, and ETS layer tables for a resource."
  @spec reset!(module()) :: :ok
  def reset!(resource) do
    Coverage.reset(resource)
    KillSwitch.enable!(resource)

    # Ets tables are keyed by the resource module, so this also covers
    # wrapper layers that delegate to Ash.DataLayer.Ets. Idempotent.
    Ash.DataLayer.Ets.stop(resource)

    :ok
  end
end
