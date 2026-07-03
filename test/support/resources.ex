defmodule AshMultiDatalayer.Test.CountingPostgres do
  @moduledoc false
  use AshMultiDatalayer.Test.CountingLayer, wraps: AshPostgres.DataLayer
end

defmodule AshMultiDatalayer.Test.FailingEts do
  @moduledoc """
  Delegates to `Ash.DataLayer.Ets` but fails upserts/destroys on demand —
  for proving that a cache-propagation failure after the authoritative
  commit degrades to a miss, never staleness.
  """
  use AshMultiDatalayer.Test.CountingLayer,
    wraps: Ash.DataLayer.Ets,
    except: [:upsert, :destroy]

  def fail!(operation) when operation in [:upsert, :destroy] do
    :persistent_term.put({__MODULE__, :fail}, operation)
  end

  def clear! do
    :persistent_term.erase({__MODULE__, :fail})
    :ok
  end

  defp failing?(operation) do
    :persistent_term.get({__MODULE__, :fail}, nil) == operation
  end

  def upsert(resource, changeset, keys, identity \\ nil) do
    if failing?(:upsert) do
      {:error, "rigged upsert failure"}
    else
      Ash.DataLayer.Ets.upsert(resource, changeset, keys, identity)
    end
  end

  def destroy(resource, changeset) do
    if failing?(:destroy) do
      {:error, "rigged destroy failure"}
    else
      Ash.DataLayer.Ets.destroy(resource, changeset)
    end
  end
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
      resource AshMultiDatalayer.Test.Resources.FailingPost
      resource AshMultiDatalayer.Test.Resources.CappedPost
      resource AshMultiDatalayer.Test.Resources.SampledPost
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

  defmodule FailingPost do
    @moduledoc false
    use Ash.Resource,
      domain: Domain,
      data_layer: AshMultiDatalayer.DataLayer,
      extensions: [AshPostgres.DataLayer]

    multi_data_layer do
      layer(:l1, AshMultiDatalayer.Test.FailingEts)
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

  defmodule CappedPost do
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
      ledger_max_entries(3)
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

  defmodule SampledPost do
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
      divergence_sampler(1.0)
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
