defmodule AshMultiDatalayer.Integration.GenerateSqliteMigrationsTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias AshMultiDatalayer.Test.MigrationResources.{
    MdlDomain,
    SqliteMdlDomain,
    SqliteMirrorDomain
  }

  setup do
    base =
      Path.join(System.tmp_dir!(), "amdl_sqlite_migrations_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base}
  end

  defp generate(domains, base, key) do
    opts = [
      snapshot_path: Path.join(base, "#{key}/snapshots"),
      migration_path: Path.join(base, "#{key}/migrations"),
      name: "test_migration",
      quiet: true,
      format: false,
      dev: false
    ]

    AshSqlite.MigrationGenerator.generate(domains, opts)
    opts
  end

  defp migration_contents(opts) do
    case Path.wildcard(Path.join(opts[:migration_path], "**/*_test_migration.exs")) do
      [file] -> File.read!(file)
      [] -> nil
    end
  end

  test "stock sqlite generator silently skips multi-datalayer resources", %{base: base} do
    opts = generate([SqliteMdlDomain], base, "stock")
    assert migration_contents(opts) == nil
  end

  test "shadowed generation produces output identical to a plain-sqlite twin",
       %{base: base} do
    shadow_opts =
      generate(
        [AshMultiDatalayer.Migration.shadow_domain(SqliteMdlDomain, AshSqlite.DataLayer)],
        base,
        "shadow"
      )

    mirror_opts = generate([SqliteMirrorDomain], base, "mirror")

    shadow = migration_contents(shadow_opts)
    mirror = migration_contents(mirror_opts)

    assert shadow, "shadowed generation produced no migration"
    assert mirror, "mirror generation produced no migration"

    # Same table/repo/attributes/FK => byte-identical migrations.
    assert shadow == mirror

    # The FK between the two multi-datalayer resources survived shadowing.
    assert shadow =~ ~r/references\(:migration_test_sqlite_authors/
  end

  test "the mix task generates for sqlite-layered multi-datalayer resources only", %{base: base} do
    opts = [
      snapshot_path: Path.join(base, "task/snapshots"),
      migration_path: Path.join(base, "task/migrations"),
      name: "test_migration",
      quiet: true,
      format: false
    ]

    Mix.Tasks.AshMultiDatalayer.GenerateSqliteMigrations.generate(
      [SqliteMdlDomain, SqliteMirrorDomain],
      opts
    )

    # SqliteMirrorDomain has no multi-datalayer resources -> filtered out; but
    # the SqliteMdlDomain shadows produce the same tables, so exactly one
    # migration.
    assert migration_contents(opts)
  end

  test "a domain with no sqlite-layered resources is skipped without requiring ash_sqlite",
       %{base: base} do
    opts = [
      snapshot_path: Path.join(base, "no_sqlite/snapshots"),
      migration_path: Path.join(base, "no_sqlite/migrations"),
      name: "test_migration",
      quiet: true,
      format: false
    ]

    # MdlDomain's resources are postgres-layered, not sqlite-layered.
    assert Mix.Tasks.AshMultiDatalayer.GenerateSqliteMigrations.generate([MdlDomain], opts) ==
             :ok

    refute migration_contents(opts)
  end

  test "run/1 tolerates flags forwarded by `mix ash.codegen` (e.g. --name) when resolving domains",
       %{base: base} do
    argv = [
      "--domains",
      inspect(SqliteMdlDomain),
      "--name",
      "add_something",
      "--snapshot-path",
      Path.join(base, "run/snapshots"),
      "--migration-path",
      Path.join(base, "run/migrations"),
      "--quiet"
    ]

    assert Mix.Tasks.AshMultiDatalayer.GenerateSqliteMigrations.run(argv) == :ok
  end
end
