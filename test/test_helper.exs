# Integration tests need the Postgres TestRepo; run them with
# `mix test --include integration` (or INTEGRATION=1 mix test).
exclude = if System.get_env("INTEGRATION") == "1", do: [], else: [:integration]

ExUnit.start(exclude: exclude)

{:ok, _} = AshMultiDatalayer.Supervisor.start_link()
:ok = AshMultiDatalayer.Test.CountingLayer.ensure_table!()
:ok = AshMultiDatalayer.Test.BlockingLayer.ensure_table!()

{:ok, _} = AshMultiDatalayer.TestRepo.start_link()
Ecto.Adapters.SQL.Sandbox.mode(AshMultiDatalayer.TestRepo, :manual)
