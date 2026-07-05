defmodule AshMultiDatalayer.Test.ObanSqlite.Migrations do
  @moduledoc """
  Migrations for the walking-skeleton SQLite file: the entry table and the Oban
  Lite `oban_jobs` table. Run via `Ecto.Migrator` in the skeleton test's
  `setup_all`. (Item 1's *codegen* is proven separately by a dry-run of
  `AshSqlite.MigrationGenerator`; this table is hand-written so the test owns one
  clean, self-contained schema.)
  """

  defmodule EntryTable do
    @moduledoc false
    use Ecto.Migration

    def up do
      # `seq` is an INTEGER PRIMARY KEY → SQLite rowid, autoincrementing (item 9).
      create table("amd_skeleton_entries", primary_key: false) do
        add :seq, :integer, primary_key: true
        add :ref, :uuid, null: false
        add :record_pk, :map
        add :payload, :map
        add :base_image, :map
        add :state, :string, null: false, default: "pending"
        add :error_class, :string
        add :attempts, :integer, default: 0
        add :behavior, :string, null: false, default: "ok"
        add :name, :string
        add :token, :string
        add :inserted_at, :utc_datetime_usec, null: false
        add :updated_at, :utc_datetime_usec, null: false
      end

      create unique_index("amd_skeleton_entries", [:ref],
               name: "amd_skeleton_entries_unique_ref_index"
             )
    end

    def down do
      drop table("amd_skeleton_entries")
    end
  end

  defmodule ObanJobsTable do
    @moduledoc false
    use Ecto.Migration

    # Dispatches to Oban.Migrations.SQLite for the ecto_sqlite3 adapter,
    # creating the Lite engine's `oban_jobs` table (item 7/11 substrate).
    # (Named `ObanJobsTable`, not `Oban`, so `Oban.Migrations` isn't captured by
    # the auto-alias of a nested module named `Oban`.)
    def up, do: Oban.Migrations.up()
    def down, do: Oban.Migrations.down()
  end
end
