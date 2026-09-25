defmodule Mix.Tasks.AshMultiDatalayer.GenerateMigrations do
  @moduledoc """
  Generates Postgres migrations for multi-datalayer resources that declare an
  `AshPostgres.DataLayer` layer.

  The stock `mix ash_postgres.generate_migrations` only discovers resources
  whose data layer is `AshPostgres.DataLayer` itself, so it skips
  multi-datalayer resources. This task shadows those resources (see
  `AshMultiDatalayer.Migration`) and runs the same generator over them,
  producing identical output to a plain-Postgres resource with the same
  `postgres` section. Plain Postgres resources are left to the stock task —
  run both (or just `mix ash.codegen`, which invokes both automatically).

  Accepts the same options and flags as `mix ash_postgres.generate_migrations`.
  """
  use Mix.Task

  @compile {:no_warn_undefined, AshPostgres.MigrationGenerator}

  @shortdoc "Generates Postgres migrations for multi-datalayer resources"
  def run(args) do
    {name, args} =
      case args do
        ["-" <> _ | _] -> {nil, args}
        [first | rest] -> {first, rest}
        [] -> {nil, []}
      end

    {opts, _} =
      OptionParser.parse!(args,
        strict: [
          domains: :string,
          snapshot_path: :string,
          migration_path: :string,
          tenant_migration_path: :string,
          quiet: :boolean,
          snapshots_only: :boolean,
          auto_name: :boolean,
          name: :string,
          no_format: :boolean,
          dry_run: :boolean,
          check: :boolean,
          dev: :boolean,
          dont_drop_columns: :boolean,
          concurrent_indexes: :boolean
        ]
      )

    domains = AshMultiDatalayer.MixHelpers.domains!(opts, args)

    opts =
      opts
      |> Keyword.put(:format, !opts[:no_format])
      |> Keyword.delete(:no_format)
      |> Keyword.put_new(:name, name)

    generate(domains, opts)
  end

  @doc false
  # Shared with AshMultiDatalayer.DataLayer.codegen/1. Shadows each domain and
  # runs the generator over the shadows; domains without any postgres-layered
  # multi-datalayer resource are skipped entirely — and so is the
  # `:ash_postgres` dependency check, since a sqlite-only (or ets-only)
  # project should never need to add it.
  def generate(domains, opts) do
    domains
    |> Enum.filter(fn domain ->
      domain
      |> Ash.Domain.Info.resources()
      |> Enum.any?(&AshMultiDatalayer.Migration.layered_as?(&1, AshPostgres.DataLayer))
    end)
    |> Enum.map(&AshMultiDatalayer.Migration.shadow_domain(&1, AshPostgres.DataLayer))
    |> case do
      [] ->
        :ok

      shadow_domains ->
        unless Code.ensure_loaded?(AshPostgres.MigrationGenerator) do
          Mix.raise(
            "mix ash_multi_datalayer.generate_migrations requires the optional " <>
              ":ash_postgres dependency. Add {:ash_postgres, \"~> 2.0\"} to your deps."
          )
        end

        AshPostgres.MigrationGenerator.generate(shadow_domains, opts)
    end
  end
end
