defmodule AshMultiDatalayer.Orchestrator.LocalOutbox.Sweeper do
  @moduledoc false
  use GenServer

  require Ash.Query

  alias AshMultiDatalayer.Orchestrator.LocalOutbox
  alias AshMultiDatalayer.Orchestrator.LocalOutbox.Flush
  alias AshMultiDatalayer.Sync.Enqueue

  def start_link(opts) do
    resources = Keyword.fetch!(opts, :resources)
    GenServer.start_link(__MODULE__, resources, name: name(resources))
  end

  @doc false
  def run_once(resources) do
    resources
    |> Enum.group_by(&LocalOutbox.outbox_resource/1)
    |> Enum.each(fn {outbox, hosts} -> sweep_outbox(outbox, hosts) end)

    :ok
  end

  @impl true
  def init(resources) do
    schedule()
    {:ok, resources}
  end

  @impl true
  def handle_info(:sweep, resources) do
    run_once(resources)
    schedule()
    {:noreply, resources}
  end

  defp sweep_outbox(outbox, hosts) do
    domain = Ash.Resource.Info.domain(outbox)
    resources = MapSet.new(hosts, &Atom.to_string/1)

    outbox
    |> Ash.Query.for_read(:read, %{}, domain: domain, authorize?: false)
    |> Ash.Query.filter(state == :pending)
    |> Ash.Query.sort(seq: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&MapSet.member?(resources, &1.resource))
    |> Enum.filter(&(Flush.chain_position(outbox, domain, &1) == :head))
    |> Enum.each(&Enqueue.flush(outbox, &1))
  end

  defp schedule do
    Process.send_after(self(), :sweep, interval_ms())
  end

  defp interval_ms do
    Application.get_env(:ash_multi_datalayer, :outbox_sweep_interval_ms, 60_000)
  end

  defp name(resources) do
    {:global, {__MODULE__, Enum.sort(resources)}}
  end
end
