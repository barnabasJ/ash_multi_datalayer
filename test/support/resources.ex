defmodule AshMultiDatalayer.Test.CountingPostgres do
  @moduledoc false
  use AshMultiDatalayer.Test.CountingLayer, wraps: AshPostgres.DataLayer
end

defmodule AshMultiDatalayer.Test.BlockingPostgres do
  @moduledoc """
  Counted Postgres source layer that can park `run_query` — for
  deterministic read/write race tests (see `AshMultiDatalayer.Test.BlockingLayer`).
  """
  use AshMultiDatalayer.Test.BlockingLayer, wraps: AshMultiDatalayer.Test.CountingPostgres
end

defmodule AshMultiDatalayer.Test.BlockingEts do
  @moduledoc """
  Ets cache layer that can park `run_query` — for deterministic
  cache-side-fetch race tests (see `AshMultiDatalayer.Test.BlockingLayer`).
  """
  use AshMultiDatalayer.Test.BlockingLayer, wraps: Ash.DataLayer.Ets
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

  @doc """
  Probabilistic failure mode: each call to `operation` independently fails
  with probability `rate` (0.0..1.0) — for stress-testing propagation
  failures under concurrent load, where a single global on/off switch can't
  express "some fraction of writes fail".
  """
  def fail_rate!(operation, rate) when operation in [:upsert, :destroy] do
    :persistent_term.put({__MODULE__, :fail_rate, operation}, rate)
  end

  def clear! do
    :persistent_term.erase({__MODULE__, :fail})
    :persistent_term.erase({__MODULE__, :fail_rate, :upsert})
    :persistent_term.erase({__MODULE__, :fail_rate, :destroy})
    :ok
  end

  defp failing?(operation) do
    :persistent_term.get({__MODULE__, :fail}, nil) == operation or
      :rand.uniform() < :persistent_term.get({__MODULE__, :fail_rate, operation}, 0.0)
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
      resource AshMultiDatalayer.Test.Resources.MirrorAuthor
      resource AshMultiDatalayer.Test.Resources.FailingPost
      resource AshMultiDatalayer.Test.Resources.CappedPost
      resource AshMultiDatalayer.Test.Resources.SampledPost
      resource AshMultiDatalayer.Test.Resources.LocalEvalOffPost
      resource AshMultiDatalayer.Test.Resources.RaceTestPost
      resource AshMultiDatalayer.Test.Resources.TestAuthor
      # Relationship-aggregate data-layer permutation matrix (parent × child):
      resource AshMultiDatalayer.Test.Resources.PgPost
      resource AshMultiDatalayer.Test.Resources.EtsPost
      resource AshMultiDatalayer.Test.Resources.PgAuthor
      resource AshMultiDatalayer.Test.Resources.MdlPgAuthor
      resource AshMultiDatalayer.Test.Resources.EtsAuthor
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
    @moduledoc """
    The relationship-aggregate **fold** example: `post_count`/`adult_post_count`
    are opted out of the same-repo SQL join (`sql_join_aggregate_overrides`), so
    they are folded from the cached related rows (0 source reads when covered).
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
      sql_join_aggregate_overrides([:post_count, :adult_post_count])
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

  # --- relationship-aggregate permutation matrix (parent × child) -----------
  #
  # Children come in three data-layer kinds, each on the same logical posts:
  #   * `PgPost`   — plain AshPostgres (shares `mdl_posts` with `TestPost`)
  #   * `TestPost` — MDL over Postgres (defined above)
  #   * `EtsPost`  — MDL without a SQL layer (single ETS layer; separate store)
  # and parents come in the same three kinds (`PgAuthor`, `MdlPgAuthor`,
  # `EtsAuthor`). Each parent carries a relationship + count aggregate to every
  # child kind, so the integration test can assert the full 3×3 behaviour.

  defmodule PgPost do
    @moduledoc "Plain-AshPostgres child sharing `mdl_posts` with `TestPost`."
    use Ash.Resource, domain: Domain, data_layer: AshPostgres.DataLayer

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
      attribute :author_id, :uuid, public?: true
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]
    end
  end

  defmodule EtsPost do
    @moduledoc """
    An MDL child **without** a SQL layer (a single ETS layer). A SQL parent
    cannot join over it — `SqlPassthrough` returns a clear error instead of
    ash_sql's `KeyError`; an MDL parent folds it. Its rows live in ETS, seeded
    separately with matching `author_id`s.
    """
    use Ash.Resource, domain: Domain, data_layer: AshMultiDatalayer.DataLayer

    multi_data_layer do
      layer(:l1, Ash.DataLayer.Ets)
      read_order([:l1])
      write_order([:l1])
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
      attribute :age, :integer, public?: true
      attribute :author_id, :uuid, public?: true
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]
    end
  end

  defmodule PgAuthor do
    @moduledoc """
    Plain-AshPostgres parent (matrix row P). A same-repo SQL child joins
    natively (`PgPost`) or through `SqlPassthrough` (`TestPost`); a non-SQL MDL
    child (`EtsPost`) cannot be joined and fails loudly. Shares `mdl_authors`.
    """
    use Ash.Resource, domain: Domain, data_layer: AshPostgres.DataLayer

    postgres do
      table "mdl_authors"
      repo(AshMultiDatalayer.TestRepo)
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
    end

    relationships do
      has_many :pg_posts, AshMultiDatalayer.Test.Resources.PgPost,
        public?: true,
        destination_attribute: :author_id

      has_many :mdl_posts, AshMultiDatalayer.Test.Resources.TestPost,
        public?: true,
        destination_attribute: :author_id

      has_many :ets_posts, AshMultiDatalayer.Test.Resources.EtsPost,
        public?: true,
        destination_attribute: :author_id
    end

    aggregates do
      count :pg_post_count, :pg_posts, do: public?(true)
      count :mdl_post_count, :mdl_posts, do: public?(true)

      count :adult_mdl_post_count, :mdl_posts do
        public? true
        filter expr(age >= 18)
      end

      count :ets_post_count, :ets_posts, do: public?(true)
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]
    end
  end

  defmodule MdlPgAuthor do
    @moduledoc """
    MDL-over-Postgres parent (matrix row M_pg). Same-repo SQL children join in
    the database by default (`SqlPassthrough`); the non-SQL `EtsPost` child is
    not same-repo SQL, so it folds. Shares `mdl_authors`.
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
      has_many :pg_posts, AshMultiDatalayer.Test.Resources.PgPost,
        public?: true,
        destination_attribute: :author_id

      has_many :mdl_posts, AshMultiDatalayer.Test.Resources.TestPost,
        public?: true,
        destination_attribute: :author_id

      has_many :ets_posts, AshMultiDatalayer.Test.Resources.EtsPost,
        public?: true,
        destination_attribute: :author_id
    end

    aggregates do
      count :pg_post_count, :pg_posts, do: public?(true)
      count :mdl_post_count, :mdl_posts, do: public?(true)

      count :adult_mdl_post_count, :mdl_posts do
        public? true
        filter expr(age >= 18)
      end

      count :ets_post_count, :ets_posts, do: public?(true)
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]
    end
  end

  defmodule EtsAuthor do
    @moduledoc """
    MDL parent **without** a SQL layer (single ETS layer; matrix row M_ets). It
    has no SQL source to join from, so every relationship aggregate folds,
    regardless of the child's data layer. Its rows live in ETS, seeded with an
    id matching the shared author.
    """
    use Ash.Resource, domain: Domain, data_layer: AshMultiDatalayer.DataLayer

    multi_data_layer do
      layer(:l1, Ash.DataLayer.Ets)
      read_order([:l1])
      write_order([:l1])
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
    end

    relationships do
      has_many :pg_posts, AshMultiDatalayer.Test.Resources.PgPost,
        public?: true,
        destination_attribute: :author_id

      has_many :mdl_posts, AshMultiDatalayer.Test.Resources.TestPost,
        public?: true,
        destination_attribute: :author_id

      has_many :ets_posts, AshMultiDatalayer.Test.Resources.EtsPost,
        public?: true,
        destination_attribute: :author_id
    end

    aggregates do
      count :pg_post_count, :pg_posts, do: public?(true)
      count :mdl_post_count, :mdl_posts, do: public?(true)

      count :adult_mdl_post_count, :mdl_posts do
        public? true
        filter expr(age >= 18)
      end

      count :ets_post_count, :ets_posts, do: public?(true)
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

  defmodule RaceTestPost do
    @moduledoc """
    Same shape as `TestPost` but its source layer can park mid-read — for
    deterministic read/write race tests (`BlockingLayer`/`BlockingPostgres`).
    Shares `mdl_posts`.
    """
    use Ash.Resource,
      domain: Domain,
      data_layer: AshMultiDatalayer.DataLayer,
      extensions: [AshPostgres.DataLayer]

    multi_data_layer do
      layer(:l1, AshMultiDatalayer.Test.BlockingEts)
      layer(:l2, AshMultiDatalayer.Test.BlockingPostgres)

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
      attribute :author_id, :uuid, public?: true
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

  defmodule MirrorAuthor do
    @moduledoc false
    use Ash.Resource,
      domain: Domain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table "mdl_authors"
      repo(AshMultiDatalayer.TestRepo)
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
    end

    relationships do
      has_many :posts, AshMultiDatalayer.Test.Resources.MirrorPost,
        public?: true,
        destination_attribute: :author_id
    end

    aggregates do
      count :post_count, :posts do
        public? true
      end

      count :adult_post_count, :posts do
        public? true
        filter expr(age >= 18)
      end
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]
    end
  end
end
