defmodule AshMultiDatalayer.Test.LocalOutbox.Remote do
  @moduledoc "LocalOutbox replication target: an ETS layer that can be armed to fail."
  use AshMultiDatalayer.Test.FailableLayer, wraps: Ash.DataLayer.Ets
end

defmodule AshMultiDatalayer.Test.LocalOutbox.FailableTarget do
  @moduledoc """
  A second failable ETS layer, distinct from `Remote` so the two can be armed
  independently as a resource's replication target while `FailableSqlite`
  independently arms that resource's LOCAL authority.
  """
  use AshMultiDatalayer.Test.FailableLayer, wraps: Ash.DataLayer.Ets
end

defmodule AshMultiDatalayer.Test.LocalOutbox.FailableSqlite do
  @moduledoc """
  A failable `AshSqlite.DataLayer` wrapper — used as a LocalOutbox LOCAL
  authority that can be armed to fail (M-5 `discard_local`, M-12 boot
  hydration). `Ash.DataLayer.Ets`'s storage is keyed by resource alone
  (regardless of which wrapper module technically calls it), so a second
  Ets-backed layer for the SAME resource would silently share physical
  storage with the first — this wraps a genuinely distinct backing store
  (SQLite) instead, exactly like the non-failable local layers do.
  """
  use AshMultiDatalayer.Test.FailableLayer, wraps: AshSqlite.DataLayer
end

defmodule AshMultiDatalayer.Test.LocalOutbox.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshMultiDatalayer.Test.LocalOutbox.Widget)
    resource(AshMultiDatalayer.Test.LocalOutbox.StaleWidget)
    resource(AshMultiDatalayer.Test.LocalOutbox.StampWidget)
    resource(AshMultiDatalayer.Test.LocalOutbox.TimestampWidget)
    resource(AshMultiDatalayer.Test.LocalOutbox.IfEmptyWidget)
    resource(AshMultiDatalayer.Test.LocalOutbox.FailableLocalWidget)
    resource(AshMultiDatalayer.Test.LocalOutbox.MtWidget)
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

defmodule AshMultiDatalayer.Test.LocalOutbox.TimestampWidget do
  @moduledoc """
  Host under LocalOutbox with a lazy-defaulted uuid PK AND a lazy-defaulted
  `create_timestamp` — the A0-2 (M-2) write_through materialization
  arbitration: the record a target receives must equal the record the local
  layer holds, field-for-field, including both kinds of lazy defaults.
  """
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
    table("lo_timestamp_widgets")
    repo(AshMultiDatalayer.Test.ObanSqlite.SkeletonRepo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
    create_timestamp(:inserted_at, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

defmodule AshMultiDatalayer.Test.LocalOutbox.IfEmptyWidget do
  @moduledoc "Host under LocalOutbox with `hydrate: :if_empty` (M-12 boot hydration coverage)."
  use Ash.Resource,
    domain: AshMultiDatalayer.Test.LocalOutbox.Domain,
    data_layer: AshMultiDatalayer.DataLayer,
    extensions: [AshSqlite.DataLayer]

  multi_data_layer do
    orchestrator(
      {AshMultiDatalayer.Orchestrator.LocalOutbox,
       outbox_resource: AshMultiDatalayer.Test.LocalOutbox.OutboxEntry,
       conflict_detection: :off,
       hydrate: :if_empty}
    )

    layer(:local, AshSqlite.DataLayer)
    layer(:remote, AshMultiDatalayer.Test.LocalOutbox.Remote)
    read_order([:local])
    write_order([:local, :remote])
  end

  sqlite do
    table("lo_ifempty_widgets")
    repo(AshMultiDatalayer.Test.ObanSqlite.SkeletonRepo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

defmodule AshMultiDatalayer.Test.LocalOutbox.FailableLocalWidget do
  @moduledoc """
  Host under LocalOutbox whose LOCAL authority is a failable SQLite layer
  (`FailableSqlite`) and whose replication target is an independently-armable
  failable ETS layer (`FailableTarget`) — for M-5 (`discard_local`
  propagating a local-write failure) and M-12 (`hydrate: :on_start` boot
  hydration, including the failing-hydrate path).
  """
  use Ash.Resource,
    domain: AshMultiDatalayer.Test.LocalOutbox.Domain,
    data_layer: AshMultiDatalayer.DataLayer,
    extensions: [AshSqlite.DataLayer]

  multi_data_layer do
    orchestrator(
      {AshMultiDatalayer.Orchestrator.LocalOutbox,
       outbox_resource: AshMultiDatalayer.Test.LocalOutbox.OutboxEntry,
       conflict_detection: :off,
       hydrate: :on_start}
    )

    layer(:local, AshMultiDatalayer.Test.LocalOutbox.FailableSqlite)
    layer(:remote, AshMultiDatalayer.Test.LocalOutbox.FailableTarget)
    read_order([:local])
    write_order([:local, :remote])
  end

  sqlite do
    table("lo_failable_local_widgets")
    repo(AshMultiDatalayer.Test.ObanSqlite.SkeletonRepo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

defmodule AshMultiDatalayer.Test.LocalOutbox.MtWidget do
  @moduledoc """
  Host under LocalOutbox with attribute-strategy multitenancy (`global?
  true`) — H5: the outbox tenant model must distinguish "unscoped" from
  "IS NULL" for a genuinely multitenant host's boot hydration / resume /
  dirty-chain checks.
  """
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
    table("lo_mt_widgets")
    repo(AshMultiDatalayer.Test.ObanSqlite.SkeletonRepo)
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? true
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:org_id, :string, public?: true)
    attribute(:name, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end
