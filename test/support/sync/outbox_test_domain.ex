defmodule AshMultiDatalayer.Test.Sync.OutboxTestDomain do
  @moduledoc "Domain for the OutboxEntry extension tests."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshMultiDatalayer.Test.Sync.TestOutboxEntry
  end
end
