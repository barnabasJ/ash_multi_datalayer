if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshMultiDatalayer.Gen.Outbox do
    @shortdoc "Generates a LocalOutbox sync domain + outbox entry resource."
    @moduledoc """
    #{@shortdoc}

    Generates the app-owned sync state for the LocalOutbox strategy: a sync
    `Ash.Domain` and an outbox entry resource carrying the
    `AshMultiDatalayer.Sync.OutboxEntry` extension (which injects the full
    contract). Composes `ash_sqlite`/`ash_oban` installers, emits the Oban Lite
    config (engine + queue), and prints the `orchestrator` DSL snippet to paste.

        mix ash_multi_datalayer.gen.outbox MyApp.Sync.OutboxEntry --repo MyApp.Repo --queue todo_sync

    With no module argument it defaults to `<App>.Sync.OutboxEntry`.
    """
    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :ash,
        example:
          "mix ash_multi_datalayer.gen.outbox MyApp.Sync.OutboxEntry --repo MyApp.Repo --queue todo_sync",
        # Bring the SQL layer + Oban wiring; their installers run automatically.
        installs: [{:ash_sqlite, "~> 0.2"}, {:ash_oban, "~> 0.8"}],
        composes: ["ash_sqlite.install", "ash_oban.install"],
        positional: [{:outbox_module, optional: true}],
        schema: [repo: :string, queue: :string, oban_instance: :string, table: :string],
        aliases: [r: :repo, q: :queue],
        defaults: [queue: "sync"]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      app = Igniter.Project.Application.app_name(igniter)
      opts = igniter.args.options
      positional = igniter.args.positional

      outbox_module =
        case positional[:outbox_module] do
          nil -> Igniter.Project.Module.module_name(igniter, "Sync.OutboxEntry")
          name -> Igniter.Project.Module.parse(name)
        end

      domain_module = domain_of(outbox_module)
      repo_module = repo_module(igniter, opts)
      queue = String.to_atom(opts[:queue] || "sync")
      table = opts[:table] || "amd_outbox_entries"
      oban_instance = opts[:oban_instance]

      # `installs:` in info/2 already runs ash_sqlite.install + ash_oban.install
      # (adds the deps and invokes their installers), so don't compose them again.
      igniter
      |> configure_oban_lite(app, repo_module, queue)
      |> create_domain(domain_module)
      |> create_outbox(outbox_module, domain_module, repo_module, queue, table, oban_instance)
      |> Igniter.add_notice("""
      LocalOutbox outbox generated: #{inspect(outbox_module)}.
      Point a resource's orchestrator at it:

          multi_data_layer do
            orchestrator {AshMultiDatalayer.Orchestrator.LocalOutbox,
              outbox_resource: #{inspect(outbox_module)},
              hydrate: :if_empty}

            layer :local, AshSqlite.DataLayer
            layer :remote, AshRemote.DataLayer
            read_order [:local]
            write_order [:local, :remote]
          end
      """)
    end

    defp repo_module(igniter, opts) do
      case opts[:repo] do
        nil -> Igniter.Project.Module.module_name(igniter, "Repo")
        repo -> Igniter.Project.Module.parse(repo)
      end
    end

    defp domain_of(outbox_module) do
      outbox_module
      |> Module.split()
      |> Enum.drop(-1)
      |> Module.concat()
    end

    # Oban Lite over the shared SQLite repo. ash_oban.install sets the Oban child
    # to `AshOban.config(...)`, reading `config :app, Oban, ...`; add the engine +
    # queue there. `configure_new` keeps re-runs idempotent.
    defp configure_oban_lite(igniter, app, repo_module, queue) do
      igniter
      |> Igniter.Project.Config.configure_new(
        "config.exs",
        app,
        [Oban, :engine],
        {:code, quote(do: Oban.Engines.Lite)}
      )
      |> Igniter.Project.Config.configure_new(
        "config.exs",
        app,
        [Oban, :repo],
        {:code, quote(do: unquote(repo_module))}
      )
      |> Igniter.Project.Config.configure_new(
        "config.exs",
        app,
        [Oban, :queues, queue],
        10
      )
    end

    defp create_domain(igniter, domain_module) do
      Igniter.Project.Module.find_and_update_or_create_module(
        igniter,
        domain_module,
        """
        use Ash.Domain, otp_app: #{inspect(Igniter.Project.Application.app_name(igniter))}

        resources do
        end
        """,
        fn zipper -> {:ok, zipper} end
      )
    end

    defp create_outbox(
           igniter,
           outbox_module,
           domain_module,
           repo_module,
           queue,
           table,
           oban_instance
         ) do
      instance_line =
        if oban_instance, do: "\n    oban_instance #{oban_instance}", else: ""

      Igniter.Project.Module.find_and_update_or_create_module(
        igniter,
        outbox_module,
        """
        use Ash.Resource,
          domain: #{inspect(domain_module)},
          data_layer: AshSqlite.DataLayer,
          extensions: [AshMultiDatalayer.Sync.OutboxEntry]

        sqlite do
          table #{inspect(table)}
          repo #{inspect(repo_module)}
        end

        outbox_entry do
          queue #{inspect(queue)}
          max_attempts 10#{instance_line}
        end
        """,
        fn zipper -> {:ok, zipper} end
      )
    end
  end
else
  defmodule Mix.Tasks.AshMultiDatalayer.Gen.Outbox do
    @shortdoc "Generates a LocalOutbox outbox resource | Install `igniter` to use"
    @moduledoc @shortdoc
    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_multi_datalayer.gen.outbox' requires igniter. Add it and run:

          mix igniter.install ash_multi_datalayer
      """)

      exit({:shutdown, 1})
    end
  end
end
