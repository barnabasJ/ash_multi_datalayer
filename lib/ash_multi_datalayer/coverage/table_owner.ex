defmodule AshMultiDatalayer.Coverage.TableOwner do
  @moduledoc """
  Owns a resource's coverage-ledger ETS table for the lifetime of the node.

  One owner process per multi-datalayer resource, started lazily under
  `AshMultiDatalayer.TableSupervisor` on the resource's first read or write.
  If the owner crashes, the supervisor restarts it and the ledger starts
  empty — the ledger is a cache index, never the source of truth.
  """
  use GenServer

  @spec start_link(module()) :: GenServer.on_start()
  def start_link(resource) do
    GenServer.start_link(__MODULE__, resource, name: name(resource))
  end

  @spec name(module()) :: atom()
  def name(resource), do: Module.concat(resource, "AshMultiDatalayer.Coverage.Owner")

  @spec table_name(module()) :: atom()
  def table_name(resource), do: :"#{resource}.AshMultiDatalayer.Coverage"

  @impl true
  def init(resource) do
    table =
      :ets.new(table_name(resource), [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, %{resource: resource, table: table}}
  end
end
