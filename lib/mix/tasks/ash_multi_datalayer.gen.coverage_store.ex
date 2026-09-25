if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshMultiDatalayer.Gen.CoverageStore do
    @shortdoc "Generates a persisted coverage-ledger store resource."
    @moduledoc """
    #{@shortdoc}

    Generates an app-owned resource carrying the
    `AshMultiDatalayer.Coverage.StoreEntry` extension (which injects the full
    contract), so `AshMultiDatalayer.Orchestrator.ProvenCoverage`'s coverage
    ledger survives a BEAM restart instead of starting cold every time. Prints
    the `orchestrator` DSL snippet to paste when done.

        mix ash_multi_datalayer.gen.coverage_store MyApp.Coverage.Entry --repo MyApp.Repo

    With no module argument it defaults to `<App>.Coverage.Entry`.

    Unlike `mix ash_multi_datalayer.gen.outbox`, this generator has no hard
    data-layer requirement — the coverage store runs no background jobs. The
    default (`AshSqlite.DataLayer`, installed automatically) is a convenience
    only; pass `--data-layer AshPostgres.DataLayer` (or any other data layer)
    to skip the ash_sqlite install and configure the resource's data layer
    yourself afterward.
    """
    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :ash,
        example:
          "mix ash_multi_datalayer.gen.coverage_store MyApp.Coverage.Entry --repo MyApp.Repo",
        installs: [{:ash_sqlite, "~> 0.2"}],
        composes: ["ash_sqlite.install"],
        positional: [{:store_module, optional: true}],
        schema: [repo: :string, data_layer: :string, table: :string],
        aliases: [r: :repo],
        defaults: [data_layer: "AshSqlite.DataLayer"]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      opts = igniter.args.options
      positional = igniter.args.positional

      store_module =
        case positional[:store_module] do
          nil -> Igniter.Project.Module.module_name(igniter, "Coverage.Entry")
          name -> Igniter.Project.Module.parse(name)
        end

      domain_module = domain_of(store_module)
      data_layer = Igniter.Project.Module.parse(opts[:data_layer])
      table = opts[:table] || "amd_coverage_entries"

      igniter
      |> create_domain(domain_module)
      |> create_store(store_module, domain_module, data_layer, table, opts)
      |> Igniter.add_notice("""
      Coverage store generated: #{inspect(store_module)}.
      Point a resource's ProvenCoverage orchestrator at it:

          multi_data_layer do
            orchestrator {AshMultiDatalayer.Orchestrator.ProvenCoverage,
              coverage_store: #{inspect(store_module)}}

            layer :cache, Ash.DataLayer.Ets
            layer :remote, MyApp.Remote.Todo
            read_order [:cache, :remote]
            write_order [:remote, :cache]
          end
      """)
    end

    defp domain_of(store_module) do
      store_module
      |> Module.split()
      |> Enum.drop(-1)
      |> Module.concat()
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

    defp create_store(igniter, store_module, domain_module, AshSqlite.DataLayer, table, opts) do
      repo_module =
        case opts[:repo] do
          nil -> Igniter.Project.Module.module_name(igniter, "Repo")
          repo -> Igniter.Project.Module.parse(repo)
        end

      Igniter.Project.Module.find_and_update_or_create_module(
        igniter,
        store_module,
        """
        use Ash.Resource,
          domain: #{inspect(domain_module)},
          data_layer: AshSqlite.DataLayer,
          extensions: [AshMultiDatalayer.Coverage.StoreEntry]

        sqlite do
          table #{inspect(table)}
          repo #{inspect(repo_module)}
        end
        """,
        fn zipper -> {:ok, zipper} end
      )
    end

    # A data layer other than the ash_sqlite convenience default: no layer
    # config block is generated (the layer's own config shape is not known
    # here) — the app configures it after generation, same as it would for
    # any other hand-written resource on that layer.
    defp create_store(igniter, store_module, domain_module, data_layer, _table, _opts) do
      Igniter.Project.Module.find_and_update_or_create_module(
        igniter,
        store_module,
        """
        use Ash.Resource,
          domain: #{inspect(domain_module)},
          data_layer: #{inspect(data_layer)},
          extensions: [AshMultiDatalayer.Coverage.StoreEntry]
        """,
        fn zipper -> {:ok, zipper} end
      )
      |> Igniter.add_notice("""
      #{inspect(store_module)} was generated with data_layer: #{inspect(data_layer)} and no
      layer-specific config block — add its table/repo (or equivalent) configuration yourself.
      """)
    end
  end
else
  defmodule Mix.Tasks.AshMultiDatalayer.Gen.CoverageStore do
    @shortdoc "Generates a coverage-store resource | Install `igniter` to use"
    @moduledoc @shortdoc
    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_multi_datalayer.gen.coverage_store' requires igniter. Add it and run:

          mix igniter.install ash_multi_datalayer
      """)

      exit({:shutdown, 1})
    end
  end
end
