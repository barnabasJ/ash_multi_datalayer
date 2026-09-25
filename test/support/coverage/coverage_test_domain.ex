defmodule AshMultiDatalayer.Test.Coverage.CoverageTestDomain do
  @moduledoc "Domain for the coverage-store extension/persistence tests."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshMultiDatalayer.Test.Coverage.TestStoreEntry)
    resource(AshMultiDatalayer.Test.Coverage.CoverageStoreResource)
  end
end
