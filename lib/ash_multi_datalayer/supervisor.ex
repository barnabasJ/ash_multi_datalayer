defmodule AshMultiDatalayer.Supervisor do
  @moduledoc """
  Supervises orchestrator state processes.

  Add it to your application's supervision tree:

      children = [
        # ...
        {AshMultiDatalayer.Supervisor, otp_app: :my_app}
      ]

  The base child is the coverage-ledger table supervisor
  (`AshMultiDatalayer.TableSupervisor`); ProvenCoverage table owners are started
  lazily, on a resource's first read or write, so with only ProvenCoverage
  configured no boot-time work is needed and passing `otp_app:`/`resources:` is
  optional.

  Strategies that require boot-time work (e.g. LocalOutbox hydration) contribute
  child specs through their `child_specs/1` callback. To discover them, pass:

    * `otp_app:` — reads `config :my_app, ash_domains: [...]`, enumerates each
      domain's resources, groups them by configured orchestrator, and starts
      each orchestrator's `child_specs/1`; or
    * `resources:` — an explicit list of resources, grouped the same way.
  """
  use Supervisor

  alias AshMultiDatalayer.DataLayer.Info

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    base = [
      {DynamicSupervisor, name: AshMultiDatalayer.TableSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(base ++ strategy_children(opts), strategy: :one_for_one)
  end

  # Group the discovered resources by their configured orchestrator and collect
  # each orchestrator's `child_specs/1`. With only ProvenCoverage configured this
  # is `[]` (its owners are lazy), so behaviour is identical to today.
  defp strategy_children(opts) do
    opts
    |> discover_resources()
    |> Enum.group_by(fn resource -> elem(Info.orchestrator(resource), 0) end)
    |> Enum.flat_map(fn {orchestrator, resources} ->
      if Code.ensure_loaded?(orchestrator) and function_exported?(orchestrator, :child_specs, 1) do
        orchestrator.child_specs(resources)
      else
        []
      end
    end)
  end

  defp discover_resources(opts) do
    cond do
      resources = opts[:resources] ->
        Enum.filter(resources, &multi_datalayer?/1)

      otp_app = opts[:otp_app] ->
        otp_app
        |> Application.get_env(:ash_domains, [])
        |> Enum.flat_map(&Ash.Domain.Info.resources/1)
        |> Enum.filter(&multi_datalayer?/1)

      true ->
        []
    end
  end

  defp multi_datalayer?(resource) do
    Ash.DataLayer.data_layer(resource) == AshMultiDatalayer.DataLayer
  rescue
    _ -> false
  end
end
