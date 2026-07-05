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

  @doc """
  The sanctioned test seam for `AshMultiDatalayer.Coverage.touch/3` (M1): a
  test can drop an entry (as `AshMultiDatalayer.Coverage.Invalidation`
  would) and then `touch_entry!/3` the stale struct to assert it does NOT
  get resurrected — `Coverage.touch/3` fires inside `covers?` on every hit
  with no deterministic way to interleave a drop between the select and the
  touch, so this wraps the same production function as the test entry point
  instead.
  """
  @spec touch_entry!(module(), term(), Coverage.Entry.t()) :: boolean()
  def touch_entry!(resource, tenant, entry), do: Coverage.touch(resource, tenant, entry)
end
