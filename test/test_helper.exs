# Integration tests need the Postgres TestRepo; run them with
# `mix test --include integration` (or INTEGRATION=1 mix test).
#
# The drop-in equivalence properties are DB-backed generated replay tests. Keep
# them opt-in so they don't interrupt ongoing integration work.
exclude =
  if System.get_env("INTEGRATION") == "1" do
    [:drop_in_equivalence_property]
  else
    [:integration, :drop_in_equivalence_property]
  end

ExUnit.start(exclude: exclude)

{:ok, _} = AshMultiDatalayer.Supervisor.start_link()
:ok = AshMultiDatalayer.Test.CountingLayer.ensure_table!()
:ok = AshMultiDatalayer.Test.BlockingLayer.ensure_table!()

{:ok, _} = AshMultiDatalayer.TestRepo.start_link()
Ecto.Adapters.SQL.Sandbox.mode(AshMultiDatalayer.TestRepo, :manual)
