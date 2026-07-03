defmodule Mix.Tasks.AshMultiDatalayer.Inspect do
  @moduledoc """
  Prints a resource's multi-datalayer state **in the current node**:
  configuration, kill-switch, and coverage-ledger summary.

      mix ash_multi_datalayer.inspect MyApp.Post

  In a running application, prefer a remote console with
  `AshMultiDatalayer.Debug.dump_ledger/2`.
  """
  use Mix.Task

  alias AshMultiDatalayer.Coverage
  alias AshMultiDatalayer.DataLayer.Info

  @shortdoc "Prints multi-datalayer state for a resource (current node)"
  def run([resource_name | _]) do
    Mix.Task.run("app.start")
    resource = Module.concat([resource_name])

    Mix.shell().info("""
    #{inspect(resource)}
      layers:      #{inspect(Enum.map(Info.layers(resource), &{&1.name, &1.module}))}
      read_order:  #{inspect(Info.read_order(resource))}
      write_order: #{inspect(Info.write_order(resource))}
      enabled?:    #{AshMultiDatalayer.enabled?(resource)}
      ledger:      #{Coverage.size(resource, nil)} entries (tenantless partition)
    """)
  end

  def run([]) do
    Mix.raise("usage: mix ash_multi_datalayer.inspect MyApp.Resource")
  end
end
