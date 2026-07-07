defmodule AshMultiDatalayer.Test.Tenancy.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshMultiDatalayer.Test.Tenancy.AttrPost
  end
end

defmodule AshMultiDatalayer.Test.Tenancy.AttrPost do
  @moduledoc """
  Attribute-strategy multitenancy (`global? true`, per P4) over the standard
  ETS-cache-over-Postgres MDL stack — for B3 (canonical tenant partitioning)
  and P4 (`global?` cross-partition invalidation) repros. Carries a second,
  similarly-named attribute (`organization_id`) purely so a tenant-derivation
  fix can be tested against an `org_id` vs `organization_id` substring
  collision.
  """
  use Ash.Resource,
    domain: AshMultiDatalayer.Test.Tenancy.Domain,
    data_layer: AshMultiDatalayer.DataLayer,
    extensions: [AshPostgres.DataLayer]

  multi_data_layer do
    layer(:l1, Ash.DataLayer.Ets)
    layer(:l2, AshMultiDatalayer.Test.CountingPostgres)

    read_order([:l1, :l2])
    write_order([:l2, :l1])
  end

  postgres do
    table "mdl_mt_attr_posts"
    repo(AshMultiDatalayer.TestRepo)
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? true
  end

  attributes do
    uuid_primary_key :id
    attribute :org_id, :string, public?: true
    attribute :organization_id, :string, public?: true
    attribute :title, :string, public?: true
    attribute :version, :integer, public?: true, default: 0
  end

  identities do
    identity :unique_title, [:org_id, :title]
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]

    # M1: a real condition-skipped upsert (ash_postgres returns
    # `{:ok, {:upsert_skipped, query, callback}}` when the row exists but
    # `upsert_condition` is false) through this attribute-multitenant
    # ProvenCoverage resource — WriteDispatch.dispatch/4 crashed calling
    # TenantKey.changeset/3 (which extracts the tenant FROM the record's
    # attributes) on that tuple.
    create :upsert_if_newer do
      accept [:org_id, :title]
      argument :version, :integer, allow_nil?: false
      change set_attribute(:version, arg(:version))
      upsert? true
      upsert_identity :unique_title
      upsert_condition expr(version < ^arg(:version))
    end
  end
end
