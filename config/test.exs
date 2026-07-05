import Config

config :ash_multi_datalayer, :assume_single_node, true
config :ash_multi_datalayer, ecto_repos: [AshMultiDatalayer.TestRepo]

config :ash_multi_datalayer, AshMultiDatalayer.TestRepo,
  username: "postgres",
  password: "postgres",
  hostname: "127.0.0.1",
  port: 5432,
  database: "ash_multi_datalayer_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

# Phase 2 walking-skeleton SQLite repo (Oban Lite over one SQLite file). Not in
# `ecto_repos` — the skeleton test owns its full lifecycle (temp file, migrate,
# Oban) in setup_all, so the `mix test` ecto.create/migrate alias never touches
# it. `database` is overridden per-run with a unique temp path at start_link.
config :ash_multi_datalayer, AshMultiDatalayer.Test.ObanSqlite.SkeletonRepo,
  database: Path.join(System.tmp_dir!(), "amd_oban_sqlite_skeleton_default.db"),
  pool_size: 1,
  journal_mode: :wal

config :ash_multi_datalayer, AshMultiDatalayer.Test.ObanSqlite.SkeletonRepoB,
  database: Path.join(System.tmp_dir!(), "amd_oban_sqlite_skeleton_b_default.db"),
  pool_size: 1,
  journal_mode: :wal

config :ash, disable_async?: true

config :logger, level: :warning
