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

config :ash, disable_async?: true

config :logger, level: :warning
