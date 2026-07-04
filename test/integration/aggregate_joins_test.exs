defmodule AshMultiDatalayer.Integration.AggregateJoinsTest do
  @moduledoc """
  Relationship aggregates across every parent × child data-layer combination
  (the aggregates ADR, option 3). Parents and children each come in three kinds:

    * `P`     — plain AshPostgres
    * `M_pg`  — MDL over Postgres
    * `M_ets` — MDL without a SQL layer (single ETS layer)

  | parent ↓ / child → | P            | M_pg                 | M_ets        |
  | P                  | native join  | join (SqlPassthrough)| loud error   |
  | M_pg               | join         | join (SqlPassthrough)| fold         |
  | M_ets              | fold         | fold                 | fold         |

  A SQL parent joins over a same-repo SQL child (plain or MDL-wrapped) in the
  database; it cannot join over a non-SQL MDL child, so that fails loudly. An
  MDL parent joins its same-repo SQL children by default and folds the rest.
  """
  use AshMultiDatalayer.DataCase, async: false

  require Ash.Query

  alias AshMultiDatalayer.Test.CountingPostgres

  alias AshMultiDatalayer.Test.Resources.{
    EtsAuthor,
    EtsPost,
    MdlPgAuthor,
    PgAuthor,
    PgPost,
    TestAuthor,
    TestPost
  }

  defp pg_reads, do: CountingLayer.count(CountingPostgres, :run_query)

  # 2 posts (one child, one adult) in each store, all with the given author_id.
  defp seed_posts!(author_id) do
    for {name, age} <- [{"kid", 10}, {"grown", 30}] do
      PgPost
      |> Ash.Changeset.for_create(:create, %{name: name, age: age, author_id: author_id})
      |> Ash.create!()

      EtsPost
      |> Ash.Changeset.for_create(:create, %{name: name, age: age, author_id: author_id})
      |> Ash.create!()
    end
  end

  setup do
    for r <- [TestAuthor, MdlPgAuthor, EtsAuthor, EtsPost, TestPost], do: reset_resource!(r)

    # Author A lives in `mdl_authors` (shared by the plain-pg and MDL-pg parents).
    pg_author = PgAuthor |> Ash.Changeset.for_create(:create, %{name: "ada"}) |> Ash.create!()
    seed_posts!(pg_author.id)

    # Author B lives in ETS (the MDL-without-SQL parent), with its own posts.
    ets_author = EtsAuthor |> Ash.Changeset.for_create(:create, %{name: "bea"}) |> Ash.create!()
    seed_posts!(ets_author.id)

    AshMultiDatalayer.Coverage.reset(TestPost)
    AshMultiDatalayer.Coverage.reset(EtsPost)
    AshMultiDatalayer.Coverage.reset(MdlPgAuthor)
    CountingLayer.reset!()

    {:ok, pg_author: pg_author, ets_author: ets_author}
  end

  # --- matrix row P: plain AshPostgres parent -------------------------------

  describe "parent = plain AshPostgres (P)" do
    test "joins a plain-SQL child and an MDL-over-SQL child in the database", %{pg_author: a} do
      r =
        PgAuthor
        |> Ash.Query.filter(id == ^a.id)
        |> Ash.Query.load([:pg_post_count, :mdl_post_count, :adult_mdl_post_count])
        |> Ash.read_one!()

      # P → P (native join) and P → M_pg (SqlPassthrough) both count the same rows.
      assert r.pg_post_count == 2
      assert r.mdl_post_count == 2
      assert r.adult_mdl_post_count == 1
    end

    test "fails loudly over a non-SQL MDL child — never a silent NotLoaded", %{pg_author: a} do
      error =
        catch_error(
          PgAuthor
          |> Ash.Query.filter(id == ^a.id)
          |> Ash.Query.load(:ets_post_count)
          |> Ash.read_one!()
        )

      assert Exception.message(error) =~ ~r/in-database join|multi-datalayer resource/
    end
  end

  # --- matrix row M_pg: MDL-over-Postgres parent ----------------------------

  describe "parent = MDL over Postgres (M_pg)" do
    test "joins same-repo SQL children and folds the non-SQL child", %{pg_author: a} do
      r =
        MdlPgAuthor
        |> Ash.Query.filter(id == ^a.id)
        |> Ash.Query.load([
          :pg_post_count,
          :mdl_post_count,
          :adult_mdl_post_count,
          :ets_post_count
        ])
        |> Ash.read_one!()

      assert r.pg_post_count == 2
      assert r.mdl_post_count == 2
      assert r.adult_mdl_post_count == 1
      # M_pg → M_ets: not same-repo SQL, so it folds — still correct.
      assert r.ets_post_count == 2
    end
  end

  # --- matrix row M_ets: MDL parent without a SQL layer ---------------------

  describe "parent = MDL without a SQL layer (M_ets)" do
    test "folds over every child kind", %{ets_author: b} do
      r =
        EtsAuthor
        |> Ash.Query.filter(id == ^b.id)
        |> Ash.Query.load([
          :pg_post_count,
          :mdl_post_count,
          :adult_mdl_post_count,
          :ets_post_count
        ])
        |> Ash.read_one!()

      assert r.pg_post_count == 2
      assert r.mdl_post_count == 2
      assert r.adult_mdl_post_count == 1
      assert r.ets_post_count == 2
    end
  end

  # --- join vs fold: where the work happens ---------------------------------

  describe "join vs fold — source reads" do
    test "an MDL parent's SQL join runs in the DB even when the related rows are cached",
         %{pg_author: a} do
      # Warm the author and the related rows so a *fold* would cost 0 reads.
      MdlPgAuthor |> Ash.read!()
      TestPost |> Ash.read!()
      reads = pg_reads()

      r =
        MdlPgAuthor
        |> Ash.Query.filter(id == ^a.id)
        |> Ash.Query.load(:mdl_post_count)
        |> Ash.read_one!()

      assert r.mdl_post_count == 2
      # One source read: the correlated COUNT ran in the database.
      assert pg_reads() == reads + 1
    end

    test "a folded aggregate costs no source read when the related rows are covered",
         %{pg_author: a} do
      TestAuthor |> Ash.read!()
      TestPost |> Ash.read!()
      reads = pg_reads()

      r =
        TestAuthor
        |> Ash.Query.filter(id == ^a.id)
        |> Ash.Query.load(:post_count)
        |> Ash.read_one!()

      assert r.post_count == 2
      assert pg_reads() == reads
    end
  end
end
