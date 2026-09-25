defmodule Mix.Tasks.AshMultiDatalayer.GenerateSqliteMigrations do
  @moduledoc """
  Generates SQLite migrations for multi-datalayer resources that declare an
  `AshSqlite.DataLayer` layer.

  The stock `mix ash_sqlite.generate_migrations` only discovers resources
  whose data layer is `AshSqlite.DataLayer` itself, so it skips
  multi-datalayer resources — exactly the resources a `LocalOutbox` offline
  stack's local layer is built from. This task shadows those resources (see
  `AshMultiDatalayer.Migration`) and runs the same generator over them,
  producing identical output to a plain-sqlite resource with the same
  `sqlite` section. Plain sqlite resources are left to the stock task — run
  both (or just `mix ash.codegen`, which invokes both automatically).

  Accepts the same options and flags as `mix ash_sqlite.generate_migrations`.
  """
  use Mix.Task

  @compile {:no_warn_undefined, AshSqlite.MigrationGenerator}

  @shortdoc "Generates SQLite migrations for multi-datalayer resources"
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
          quiet: :boolean,
          name: :string,
          no_format: :boolean,
          dry_run: :boolean,
          check: :boolean,
          dev: :boolean,
          auto_name: :boolean,
          drop_columns: :boolean
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
  # runs the generator over the shadows; domains without any sqlite-layered
  # multi-datalayer resource are skipped entirely — and so is the
  # `:ash_sqlite` dependency check, since a postgres-only project should never
  # need to add it.
  def generate(domains, opts) do
    domains
    |> Enum.filter(fn domain ->
      domain
      |> Ash.Domain.Info.resources()
      |> Enum.any?(&AshMultiDatalayer.Migration.layered_as?(&1, AshSqlite.DataLayer))
    end)
    |> Enum.map(&AshMultiDatalayer.Migration.shadow_domain(&1, AshSqlite.DataLayer))
    |> case do
      [] ->
        :ok

      shadow_domains ->
        unless Code.ensure_loaded?(AshSqlite.MigrationGenerator) do
          Mix.raise(
            "mix ash_multi_datalayer.generate_sqlite_migrations requires the optional " <>
              ":ash_sqlite dependency. Add {:ash_sqlite, \"~> 0.2\"} to your deps."
          )
        end

        AshSqlite.MigrationGenerator.generate(shadow_domains, opts)
    end
  end
end
