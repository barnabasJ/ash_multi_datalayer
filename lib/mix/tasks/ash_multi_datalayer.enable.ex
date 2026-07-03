defmodule Mix.Tasks.AshMultiDatalayer.Enable do
  @moduledoc """
  Re-enables layered behaviour for a resource **in the current node**:

      mix ash_multi_datalayer.enable MyApp.Post

  See `mix ash_multi_datalayer.disable` for the remote-console caveat.
  """
  use Mix.Task

  @shortdoc "Re-enables layered behaviour for a resource (current node)"
  def run([resource_name | _]) do
    Mix.Task.run("app.start")
    resource = Module.concat([resource_name])
    :ok = AshMultiDatalayer.enable!(resource)
    Mix.shell().info("#{inspect(resource)} enabled (this node only)")
  end

  def run([]) do
    Mix.raise("usage: mix ash_multi_datalayer.enable MyApp.Resource")
  end
end
