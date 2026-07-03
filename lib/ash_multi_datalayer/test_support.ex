defmodule AshMultiDatalayer.TestSupport do
  @moduledoc """
  Helpers for host applications' test suites.

      setup do
        AshMultiDatalayer.TestSupport.reset!(MyApp.Post)
        # Clear your cache layers' own storage too, e.g. for Ets layers:
        Ash.DataLayer.Ets.stop(MyApp.Post)
        :ok
      end

  `reset!/1` clears the state **this library owns** for a resource — the
  coverage ledger and the kill-switch. The underlying layers' storage is
  theirs to manage: the library is data-layer agnostic and there is no
  generic "wipe" in the `Ash.DataLayer` behaviour, so clear cache layers
  with their own APIs (as above for `Ash.DataLayer.Ets`).
  """

  alias AshMultiDatalayer.Coverage
  alias AshMultiDatalayer.KillSwitch

  @doc "Clears the coverage ledger and kill-switch for a resource."
  @spec reset!(module()) :: :ok
  def reset!(resource) do
    Coverage.reset(resource)
    KillSwitch.enable!(resource)
    :ok
  end
end
