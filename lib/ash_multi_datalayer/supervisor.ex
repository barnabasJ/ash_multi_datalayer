defmodule AshMultiDatalayer.Supervisor do
  @moduledoc """
  Supervises the per-resource coverage-ledger table owners.

  Add it to your application's supervision tree:

      children = [
        # ...
        AshMultiDatalayer.Supervisor
      ]

  Table owners are started lazily, on a resource's first read or write.
  """
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {DynamicSupervisor, name: AshMultiDatalayer.TableSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
