defmodule AshMultiDatalayer.Test.ObanSqlite.SkeletonDomain do
  @moduledoc "Phase 2 walking-skeleton domain."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshMultiDatalayer.Test.ObanSqlite.Entry
  end
end
