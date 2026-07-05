defmodule AshMultiDatalayer.Test.Sync.TestOutboxEntry do
  @moduledoc """
  Exercises the `AshMultiDatalayer.Sync.OutboxEntry` extension: the app-side
  module is tiny — a `sqlite` block and an `outbox_entry` config block — and the
  extension injects the entire contract (attributes, actions, ash_oban trigger).
  """
  use Ash.Resource,
    domain: AshMultiDatalayer.Test.Sync.OutboxTestDomain,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshMultiDatalayer.Sync.OutboxEntry]

  sqlite do
    table "amd_test_outbox"
    repo(AshMultiDatalayer.Test.ObanSqlite.SkeletonRepo)
  end

  outbox_entry do
    queue(:test_outbox)
    max_attempts(5)
  end
end
