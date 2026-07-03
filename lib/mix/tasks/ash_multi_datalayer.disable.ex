defmodule Mix.Tasks.AshMultiDatalayer.Disable do
  @moduledoc """
  Flips the runtime kill-switch off for a resource **in the current node**:

      mix ash_multi_datalayer.disable MyApp.Post

  Note: mix tasks run in their own BEAM node — to disable a resource in a
  *running* application, use a remote console instead:

      AshMultiDatalayer.disable!(MyApp.Post)
  """
  use Mix.Task

  @shortdoc "Disables layered behaviour for a resource (current node)"
  def run([resource_name | _]) do
    Mix.Task.run("app.start")
    resource = Module.concat([resource_name])
    :ok = AshMultiDatalayer.disable!(resource)
    Mix.shell().info("#{inspect(resource)} disabled (this node only)")
  end

  def run([]) do
    Mix.raise("usage: mix ash_multi_datalayer.disable MyApp.Resource")
  end
end
