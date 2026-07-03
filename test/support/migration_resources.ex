defmodule AshMultiDatalayer.Test.MigrationResources do
  @moduledoc """
  Twin resource pairs for proving that migration generation for a
  multi-datalayer resource produces output identical to a plain-Postgres
  resource with the same `postgres` section — including a belongs_to between
  two multi-datalayer resources (FK references must survive shadowing).
  """

  defmodule MdlDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(AshMultiDatalayer.Test.MigrationResources.MdlAuthor)
      resource(AshMultiDatalayer.Test.MigrationResources.MdlPost)
    end
  end

  defmodule MdlAuthor do
    @moduledoc false
    use Ash.Resource,
      domain: MdlDomain,
      data_layer: AshMultiDatalayer.DataLayer,
      extensions: [AshPostgres.DataLayer]

    multi_data_layer do
      layer(:l1, Ash.DataLayer.Ets)
      layer(:l2, AshPostgres.DataLayer)
      read_order([:l1, :l2])
      write_order([:l2, :l1])
    end

    postgres do
      table("migration_test_authors")
      repo(AshMultiDatalayer.TestRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
    end
  end

  defmodule MdlPost do
    @moduledoc false
    use Ash.Resource,
      domain: MdlDomain,
      data_layer: AshMultiDatalayer.DataLayer,
      extensions: [AshPostgres.DataLayer]

    multi_data_layer do
      layer(:l1, Ash.DataLayer.Ets)
      layer(:l2, AshPostgres.DataLayer)
      read_order([:l1, :l2])
      write_order([:l2, :l1])
    end

    postgres do
      table("migration_test_posts")
      repo(AshMultiDatalayer.TestRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
      attribute(:age, :integer, public?: true)
    end

    relationships do
      belongs_to(:author, MdlAuthor, public?: true)
    end
  end

  defmodule MirrorDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(AshMultiDatalayer.Test.MigrationResources.MirrorAuthor)
      resource(AshMultiDatalayer.Test.MigrationResources.MirrorPost)
    end
  end

  defmodule MirrorAuthor do
    @moduledoc false
    use Ash.Resource,
      domain: MirrorDomain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table("migration_test_authors")
      repo(AshMultiDatalayer.TestRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
    end
  end

  defmodule MirrorPost do
    @moduledoc false
    use Ash.Resource,
      domain: MirrorDomain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table("migration_test_posts")
      repo(AshMultiDatalayer.TestRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
      attribute(:age, :integer, public?: true)
    end

    relationships do
      belongs_to(:author, MirrorAuthor, public?: true)
    end
  end
end
