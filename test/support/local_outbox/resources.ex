defmodule AshMultiDatalayer.Test.LocalOutbox.Remote do
  @moduledoc "LocalOutbox replication target: an ETS layer that can be armed to fail."
  use AshMultiDatalayer.Test.FailableLayer, wraps: Ash.DataLayer.Ets
end

defmodule AshMultiDatalayer.Test.LocalOutbox.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshMultiDatalayer.Test.LocalOutbox.Widget)
    resource(AshMultiDatalayer.Test.LocalOutbox.StaleWidget)
    resource(AshMultiDatalayer.Test.LocalOutbox.StampWidget)
    resource(AshMultiDatalayer.Test.LocalOutbox.OutboxEntry)
  end
end

defmodule AshMultiDatalayer.Test.LocalOutbox.OutboxEntry do
  @moduledoc "Outbox for the LocalOutbox strategy tests."
  use Ash.Resource,
    domain: AshMultiDatalayer.Test.LocalOutbox.Domain,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshMultiDatalayer.Sync.OutboxEntry]

  sqlite do
    table("lo_outbox")
    repo(AshMultiDatalayer.Test.ObanSqlite.SkeletonRepo)
  end

  outbox_entry do
    queue(:lo_sync)
  end
end

defmodule AshMultiDatalayer.Test.LocalOutbox.Widget do
  @moduledoc "Host resource under LocalOutbox with LWW (`conflict_detection: :off`)."
  use Ash.Resource,
    domain: AshMultiDatalayer.Test.LocalOutbox.Domain,
    data_layer: AshMultiDatalayer.DataLayer,
    extensions: [AshSqlite.DataLayer]

  multi_data_layer do
    orchestrator(
      {AshMultiDatalayer.Orchestrator.LocalOutbox,
       outbox_resource: AshMultiDatalayer.Test.LocalOutbox.OutboxEntry,
       conflict_detection: :off,
       hydrate: :manual}
    )

    layer(:local, AshSqlite.DataLayer)
    layer(:remote, AshMultiDatalayer.Test.LocalOutbox.Remote)
    read_order([:local])
    write_order([:local, :remote])
  end

  sqlite do
    table("lo_widgets")
    repo(AshMultiDatalayer.Test.ObanSqlite.SkeletonRepo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
    attribute(:count, :integer, default: 0, public?: true)
    attribute(:updated_at, :integer, default: 0, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

defmodule AshMultiDatalayer.Test.LocalOutbox.StaleWidget do
  @moduledoc "Host resource under LocalOutbox with `{:stale_check, :version}`."
  use Ash.Resource,
    domain: AshMultiDatalayer.Test.LocalOutbox.Domain,
    data_layer: AshMultiDatalayer.DataLayer,
    extensions: [AshSqlite.DataLayer]

  multi_data_layer do
    orchestrator(
      {AshMultiDatalayer.Orchestrator.LocalOutbox,
       outbox_resource: AshMultiDatalayer.Test.LocalOutbox.OutboxEntry,
       conflict_detection: {:stale_check, :version},
       hydrate: :manual}
    )

    layer(:local, AshSqlite.DataLayer)
    layer(:remote, AshMultiDatalayer.Test.LocalOutbox.Remote)
    read_order([:local])
    write_order([:local, :remote])
  end

  sqlite do
    table("lo_stale_widgets")
    repo(AshMultiDatalayer.Test.ObanSqlite.SkeletonRepo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
    attribute(:version, :integer, default: 1, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

defmodule AshMultiDatalayer.Test.LocalOutbox.StampWidget do
  @moduledoc "Host under LocalOutbox with `{:stale_check, :seen_at}` — a datetime conflict field."
  use Ash.Resource,
    domain: AshMultiDatalayer.Test.LocalOutbox.Domain,
    data_layer: AshMultiDatalayer.DataLayer,
    extensions: [AshSqlite.DataLayer]

  multi_data_layer do
    orchestrator(
      {AshMultiDatalayer.Orchestrator.LocalOutbox,
       outbox_resource: AshMultiDatalayer.Test.LocalOutbox.OutboxEntry,
       conflict_detection: {:stale_check, :seen_at},
       hydrate: :manual}
    )

    layer(:local, AshSqlite.DataLayer)
    layer(:remote, AshMultiDatalayer.Test.LocalOutbox.Remote)
    read_order([:local])
    write_order([:local, :remote])
  end

  sqlite do
    table("lo_stamp_widgets")
    repo(AshMultiDatalayer.Test.ObanSqlite.SkeletonRepo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
    attribute(:seen_at, :utc_datetime_usec, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end
