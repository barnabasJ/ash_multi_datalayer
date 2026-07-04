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
      resource AshMultiDatalayer.Test.Resources.LocalEvalOffPost
      resource AshMultiDatalayer.Test.Resources.TestAuthor
      resource AshMultiDatalayer.Test.Resources.OverrideAggAuthor
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

    relationships do
      belongs_to :author, AshMultiDatalayer.Test.Resources.TestAuthor,
        public?: true,
        attribute_writable?: true
    end

    calculations do
      calculate :adult?, :boolean, expr(age >= 18) do
        public? true
      end
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]
    end
  end

  defmodule TestAuthor do
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
      table "mdl_authors"
      repo(AshMultiDatalayer.TestRepo)
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
    end

    relationships do
      has_many :posts, AshMultiDatalayer.Test.Resources.TestPost,
        public?: true,
        destination_attribute: :author_id
    end

    aggregates do
      count :post_count, :posts do
        public? true
      end

      # A filtered aggregate — exercises the fold's in-memory filter path.
      count :adult_post_count, :posts do
        public? true
        filter expr(age >= 18)
      end
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]
    end
  end

  defmodule OverrideAggAuthor do
    @moduledoc """
    Same as `TestAuthor` but `post_count` is in `fold_aggregate_overrides`, so
    it is handed to the source of truth instead of folded. The SQL source cannot
    compute a relationship aggregate over the MDL-wrapped `TestPost`, so this
    must fail LOUDLY (never a silent NotLoaded). Shares `mdl_authors`.
    """
    use Ash.Resource,
      domain: Domain,
      data_layer: AshMultiDatalayer.DataLayer,
      extensions: [AshPostgres.DataLayer]

    multi_data_layer do
      layer(:l1, Ash.DataLayer.Ets)
      layer(:l2, AshMultiDatalayer.Test.CountingPostgres)

      read_order([:l1, :l2])
      write_order([:l2, :l1])
      fold_aggregate_overrides([:post_count])
    end

    postgres do
      table "mdl_authors"
      repo(AshMultiDatalayer.TestRepo)
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
    end

    relationships do
      has_many :posts, AshMultiDatalayer.Test.Resources.TestPost,
        public?: true,
        destination_attribute: :author_id
    end

    aggregates do
      count :post_count, :posts do
        public? true
      end
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

  defmodule LocalEvalOffPost do
    @moduledoc """
    Same layers as `TestPost` but with local evaluation disabled — every
    calculation is fetched from the source of truth (the pre-local-eval merge
    path). Shares the `mdl_posts` table.
    """
    use Ash.Resource,
      domain: Domain,
      data_layer: AshMultiDatalayer.DataLayer,
      extensions: [AshPostgres.DataLayer]

    multi_data_layer do
      layer(:l1, Ash.DataLayer.Ets)
      layer(:l2, AshMultiDatalayer.Test.CountingPostgres)

      read_order([:l1, :l2])
      write_order([:l2, :l1])
      local_evaluation?(false)
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

    calculations do
      calculate :adult?, :boolean, expr(age >= 18) do
        public? true
      end
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
