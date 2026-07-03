defmodule AshMultiDatalayer.Integration.GenerateMigrationsTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias AshMultiDatalayer.Test.MigrationResources.{MdlDomain, MirrorDomain}

  setup do
    base = Path.join(System.tmp_dir!(), "amdl_migrations_#{System.unique_integer([:positive])}")
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

    AshPostgres.MigrationGenerator.generate(domains, opts)
    opts
  end

  defp migration_contents(opts) do
    case Path.wildcard(Path.join(opts[:migration_path], "**/*_test_migration.exs")) do
      [file] -> File.read!(file)
      [] -> nil
    end
  end

  test "stock generator silently skips multi-datalayer resources", %{base: base} do
    opts = generate([MdlDomain], base, "stock")
    assert migration_contents(opts) == nil
  end

  test "shadowed generation produces output identical to a plain-postgres twin",
       %{base: base} do
    shadow_opts =
      generate([AshMultiDatalayer.Migration.shadow_domain(MdlDomain)], base, "shadow")

    mirror_opts = generate([MirrorDomain], base, "mirror")

    shadow = migration_contents(shadow_opts)
    mirror = migration_contents(mirror_opts)

    assert shadow, "shadowed generation produced no migration"
    assert mirror, "mirror generation produced no migration"

    # Same table/repo/attributes/FK => byte-identical migrations.
    assert shadow == mirror

    # The FK between the two multi-datalayer resources survived shadowing.
    assert shadow =~ ~r/references\(:migration_test_authors/
  end

  test "the mix task generates for multi-datalayer resources only", %{base: base} do
    opts = [
      snapshot_path: Path.join(base, "task/snapshots"),
      migration_path: Path.join(base, "task/migrations"),
      name: "test_migration",
      quiet: true,
      format: false
    ]

    Mix.Tasks.AshMultiDatalayer.GenerateMigrations.generate([MdlDomain, MirrorDomain], opts)

    # MirrorDomain has no multi-datalayer resources -> filtered out; but the
    # MdlDomain shadows produce the same tables, so exactly one migration.
    assert migration_contents(opts)
  end
end
