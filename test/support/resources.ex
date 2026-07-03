defmodule AshMultiDatalayer.Test.CountingPostgres do
  @moduledoc false
  use AshMultiDatalayer.Test.CountingLayer, wraps: AshPostgres.DataLayer
end

defmodule AshMultiDatalayer.Test.Resources do
  @moduledoc """
  Canonical test resources.

  `TestPost` (multi-datalayer: ETS cache over counted Postgres) and
  `MirrorPost` (plain AshPostgres) share the `mdl_posts` table, so behaviour
  can be compared and data seeded/read across the two stacks.
  `SingleLayerPost` routes both orders to the counted Postgres layer only —
  the drop-in-replacement configuration.
  """

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshMultiDatalayer.Test.Resources.TestPost
      resource AshMultiDatalayer.Test.Resources.SingleLayerPost
      resource AshMultiDatalayer.Test.Resources.MirrorPost
    end
  end

  defmodule TestPost do
    @moduledoc false
    use Ash.Resource,
      domain: Domain,
      data_layer: AshMultiDatalayer.DataLayer,
      extensions: [AshPostgres.DataLayer]

    multi_data_layer do
      layer(:l1, Ash.DataLayer.Ets)
      layer(:l2, AshMultiDatalayer.Test.CountingPostgres)

      read_order([:l1, :l2])
      write_order([:l2, :l1])
    end

    postgres do
      table "mdl_posts"
      repo(AshMultiDatalayer.TestRepo)
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
      attribute :age, :integer, public?: true
      attribute :score, :decimal, public?: true
      attribute :published_at, :date, public?: true
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]
    end
  end

  defmodule SingleLayerPost do
    @moduledoc false
    use Ash.Resource,
      domain: Domain,
      data_layer: AshMultiDatalayer.DataLayer,
      extensions: [AshPostgres.DataLayer]

    multi_data_layer do
      layer(:l2, AshMultiDatalayer.Test.CountingPostgres)

      read_order([:l2])
      write_order([:l2])
    end

    postgres do
      table "mdl_posts"
      repo(AshMultiDatalayer.TestRepo)
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
      attribute :age, :integer, public?: true
      attribute :score, :decimal, public?: true
      attribute :published_at, :date, public?: true
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]
    end
  end

  defmodule MirrorPost do
    @moduledoc false
    use Ash.Resource,
      domain: Domain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table "mdl_posts"
      repo(AshMultiDatalayer.TestRepo)
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
      attribute :age, :integer, public?: true
      attribute :score, :decimal, public?: true
      attribute :published_at, :date, public?: true
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]
    end
  end
end
