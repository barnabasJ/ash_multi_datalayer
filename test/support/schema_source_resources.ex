defmodule AshMultiDatalayer.Test.SchemaSource do
  @moduledoc """
  Regression fixture for `AshMultiDatalayer.DataLayer.source/1`: a
  `ProvenCoverage` resource whose SQL layer is the *cache*, not the
  authority (`read_source_layer/1`, ProvenCoverage's `authority/1` answer,
  is the last `read_order` entry — here a non-SQL `Ets`-backed "remote"
  stand-in). Ecto's own schema macro (`Ash.Schema.define_schema/0`) calls
  `Ash.DataLayer.source/1` at compile time to resolve the table for
  `schema Ash.DataLayer.source(__MODULE__) do ... end` — before this fix,
  that call asked only the authority layer (the non-SQL one here), which
  doesn't implement `source/1` meaningfully, silently resolving to `""` and
  breaking any Ecto-`Queryable`-based operation on the SQL cache layer (an
  upsert's `Ecto.Query.from(row in resource, ...)`, notably).
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshMultiDatalayer.Test.SchemaSource.Widget)
  end
end

defmodule AshMultiDatalayer.Test.SchemaSource.Widget do
  @moduledoc false
  use Ash.Resource,
    domain: AshMultiDatalayer.Test.SchemaSource,
    data_layer: AshMultiDatalayer.DataLayer,
    extensions: [Ash.DataLayer.Ets, AshSqlite.DataLayer]

  multi_data_layer do
    orchestrator(AshMultiDatalayer.Orchestrator.ProvenCoverage)
    layer(:cache, AshSqlite.DataLayer)
    layer(:remote, Ash.DataLayer.Ets)
    read_order([:cache, :remote])
    write_order([:remote, :cache])
  end

  ets do
    private?(true)
  end

  sqlite do
    table("schema_source_widgets")
    repo(AshMultiDatalayer.Test.ObanSqlite.SkeletonRepo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
  end

  actions do
    defaults([:read, create: :*])
  end
end
