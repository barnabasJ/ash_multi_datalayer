if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshMultiDatalayer.Install do
    @shortdoc "Installs ash_multi_datalayer: supervisor + formatter wiring."
    @moduledoc """
    #{@shortdoc}

    Adds `AshMultiDatalayer.Supervisor` (with `otp_app:`) to the application's
    supervision tree — it discovers resources by orchestrator and starts each
    strategy's `child_specs/1` (ProvenCoverage's table owners stay lazy; a
    LocalOutbox resource hydrates at boot) — and imports the library's formatter
    rules.

        mix ash_multi_datalayer.install
    """
    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :ash,
        example: "mix ash_multi_datalayer.install",
        schema: [],
        positional: []
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      app = Igniter.Project.Application.app_name(igniter)

      igniter
      |> Igniter.Project.Formatter.import_dep(:ash_multi_datalayer)
      |> Igniter.Project.Application.add_new_child(
        {AshMultiDatalayer.Supervisor, {:code, quote(do: [otp_app: unquote(app)])}}
      )
    end
  end
else
  defmodule Mix.Tasks.AshMultiDatalayer.Install do
    @shortdoc "Installs ash_multi_datalayer | Install `igniter` to use"
    @moduledoc @shortdoc
    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_multi_datalayer.install' requires igniter. Add it and run:

          mix igniter.install ash_multi_datalayer
      """)

      exit({:shutdown, 1})
    end
  end
end
