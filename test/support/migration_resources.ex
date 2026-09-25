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

  defmodule SqliteMdlDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(AshMultiDatalayer.Test.MigrationResources.SqliteMdlAuthor)
      resource(AshMultiDatalayer.Test.MigrationResources.SqliteMdlPost)
    end
  end

  defmodule SqliteMdlAuthor do
    @moduledoc false
    use Ash.Resource,
      domain: SqliteMdlDomain,
      data_layer: AshMultiDatalayer.DataLayer,
      extensions: [AshSqlite.DataLayer]

    multi_data_layer do
      layer(:l1, Ash.DataLayer.Ets)
      layer(:l2, AshSqlite.DataLayer)
      read_order([:l1, :l2])
      write_order([:l2, :l1])
    end

    sqlite do
      table("migration_test_sqlite_authors")
      repo(AshMultiDatalayer.Test.ObanSqlite.SkeletonRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
    end
  end

  defmodule SqliteMdlPost do
    @moduledoc false
    use Ash.Resource,
      domain: SqliteMdlDomain,
      data_layer: AshMultiDatalayer.DataLayer,
      extensions: [AshSqlite.DataLayer]

    multi_data_layer do
      layer(:l1, Ash.DataLayer.Ets)
      layer(:l2, AshSqlite.DataLayer)
      read_order([:l1, :l2])
      write_order([:l2, :l1])
    end

    sqlite do
      table("migration_test_sqlite_posts")
      repo(AshMultiDatalayer.Test.ObanSqlite.SkeletonRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
      attribute(:age, :integer, public?: true)
    end

    relationships do
      belongs_to(:author, SqliteMdlAuthor, public?: true)
    end
  end

  defmodule SqliteMirrorDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(AshMultiDatalayer.Test.MigrationResources.SqliteMirrorAuthor)
      resource(AshMultiDatalayer.Test.MigrationResources.SqliteMirrorPost)
    end
  end

  defmodule SqliteMirrorAuthor do
    @moduledoc false
    use Ash.Resource,
      domain: SqliteMirrorDomain,
      data_layer: AshSqlite.DataLayer

    sqlite do
      table("migration_test_sqlite_authors")
      repo(AshMultiDatalayer.Test.ObanSqlite.SkeletonRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
    end
  end

  defmodule SqliteMirrorPost do
    @moduledoc false
    use Ash.Resource,
      domain: SqliteMirrorDomain,
      data_layer: AshSqlite.DataLayer

    sqlite do
      table("migration_test_sqlite_posts")
      repo(AshMultiDatalayer.Test.ObanSqlite.SkeletonRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
      attribute(:age, :integer, public?: true)
    end

    relationships do
      belongs_to(:author, SqliteMirrorAuthor, public?: true)
    end
  end

  defmodule NoPostgresDomain do
    @moduledoc """
    Has no postgres-layered resource anywhere — proves that generating
    migrations for a domain like this never needs `:ash_postgres` at all.
    """
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(AshMultiDatalayer.Test.MigrationResources.EtsOnlyResource)
    end
  end

  defmodule EtsOnlyResource do
    @moduledoc false
    use Ash.Resource,
      domain: NoPostgresDomain,
      data_layer: AshMultiDatalayer.DataLayer,
      extensions: [Ash.DataLayer.Ets]

    multi_data_layer do
      layer(:l1, Ash.DataLayer.Ets)
      layer(:l2, Ash.DataLayer.Ets)
      read_order([:l1])
      write_order([:l1, :l2])
    end

    ets do
      table(:migration_test_ets_only)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
    end
  end
end
