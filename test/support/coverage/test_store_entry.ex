defmodule AshMultiDatalayer.Test.Coverage.TestStoreEntry do
  @moduledoc """
  Exercises the `AshMultiDatalayer.Coverage.StoreEntry` extension: the app-side
  module is a bare `data_layer:` + `extensions:` declaration, and the extension
  injects the entire contract (attributes, identity, actions).

  Unlike `AshMultiDatalayer.Test.Sync.TestOutboxEntry` (which requires a real
  SQL layer + repo for its ash_oban flush jobs), this extension has no SQL
  requirement — plain `Ash.DataLayer.Ets` is enough.

  `private?(false)` deliberately: `AshMultiDatalayer.Coverage.Store`'s
  write-through runs inside a spawned `Task`, a different process from the
  caller — a private (per-process) Ets table would be invisible across that
  boundary, exactly the gap a real SQL-backed store never has (its table is
  already shared by every process). Tests clear the table between runs
  instead (see `store_test.exs`'s `setup`), the same way the SQL-backed
  outbox tests `DELETE FROM` between runs.
  """
  use Ash.Resource,
    domain: AshMultiDatalayer.Test.Coverage.CoverageTestDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshMultiDatalayer.Coverage.StoreEntry]

  ets do
    private?(false)
  end
end
