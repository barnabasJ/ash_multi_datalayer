defmodule AshMultiDatalayer.Integration.DropInEquivalencePropertyTest do
  @moduledoc """
  Replays generated logical operation sequences against the multi-datalayer
  resource and the plain single-datalayer resource, asserting that callers see
  the same behaviour.

  UUID primary keys are generated independently on each replay, so comparisons
  intentionally normalise results down to public field values.
  """
  use AshMultiDatalayer.DataCase, async: false
  use ExUnitProperties

  @moduletag :property
  @moduletag :drop_in_equivalence_property
  @moduletag timeout: 6_000_000
  @moduletag sandbox_checkout_opts: [ownership_timeout: 6_000_000]

  alias AshMultiDatalayer.Test.Generators
  alias AshMultiDatalayer.Test.Resources.{MirrorAuthor, TestAuthor}

  require Ash.Query

  @runs 500
  @names ~w(a b c d e) ++ Enum.map(1..145, &"name_#{&1}")
  @ages [nil] ++ Enum.to_list(0..128)
  @dates [nil] ++ Enum.map(1..49, &Date.add(~D[2026-01-01], &1 * 7))
  @scores [nil] ++ Enum.map(0..48, &Decimal.div(Decimal.new(&1), Decimal.new(4)))
  @fields [:name, :age, :score, :published_at]
  @author_names Enum.map(1..100, &"author_#{&1}")
  @sort_specs [
                [:name],
                [:age],
                [:published_at],
                [:name, :age],
                [:name, :published_at],
                [:age, :name],
                [:age, :published_at],
                [:published_at, :name],
                [:published_at, :age],
                [:name, :age, :published_at],
                [:age, :published_at, :name],
                [:published_at, :name, :age]
              ]
              |> Enum.flat_map(fn fields ->
                for direction_seed <- 0..7 do
                  fields
                  |> Enum.with_index()
                  |> Enum.map(fn {field, index} ->
                    direction =
                      if Bitwise.band(direction_seed, Bitwise.bsl(1, index)) == 0,
                        do: :asc,
                        else: :desc

                    {field, direction}
                  end)
                end
              end)

  property "multi-datalayer resource is observationally equivalent to the plain datalayer" do
    check all(
            initial_rows <- StreamData.list_of(row_attrs(), max_length: 300),
            ops <- StreamData.list_of(operation(), min_length: 100, max_length: 800),
            max_runs: @runs
          ) do
      try do
        reset_store!()
        seed_rows!(TestPost, initial_rows)
        multi_results = replay(TestPost, ops)

        reset_store!()
        seed_rows!(MirrorPost, initial_rows)
        single_results = replay(MirrorPost, ops)

        assert multi_results == single_results
      after
        reset_store!()
      end
    end
  end

  property "relationship aggregates match the plain datalayer" do
    check all(
            authors <- StreamData.list_of(author_spec(), max_length: 100),
            max_runs: @runs
          ) do
      try do
        reset_store!()
        seed_authors!(TestAuthor, TestPost, authors)
        multi_results = aggregate_reads(TestAuthor, TestPost)

        reset_store!()
        seed_authors!(MirrorAuthor, MirrorPost, authors)
        single_results = aggregate_reads(MirrorAuthor, MirrorPost)

        assert multi_results == single_results
      after
        reset_store!()
      end
    end
  end

  defp operation do
    StreamData.one_of([
      row_attrs() |> StreamData.map(&{:create, &1}),
      StreamData.bind(StreamData.member_of(@names), fn name ->
        update_attrs() |> StreamData.map(&{:update_by_name, name, &1})
      end),
      StreamData.bind(Generators.statement(), fn statement ->
        update_attrs() |> StreamData.map(&{:update_by_filter, statement, &1})
      end),
      StreamData.member_of(@names) |> StreamData.map(&{:destroy_by_name, &1}),
      Generators.statement() |> StreamData.map(&{:destroy_by_filter, &1}),
      StreamData.bind(Generators.statement(), fn statement ->
        Generators.select_subset()
        |> StreamData.map(&{:read_twice, statement, &1})
      end),
      StreamData.bind(Generators.statement(), fn statement ->
        Generators.select_subset()
        |> StreamData.map(&{:read_calc_twice, statement, &1})
      end),
      StreamData.bind(Generators.statement(), fn statement ->
        query_shape()
        |> StreamData.map(&{:read_page_twice, statement, &1})
      end)
    ])
  end

  defp query_shape do
    StreamData.fixed_map(%{
      select: Generators.select_subset(),
      sort: sort_spec(),
      limit: StreamData.integer(1..130),
      offset: StreamData.integer(0..50)
    })
  end

  defp sort_spec do
    StreamData.member_of(@sort_specs)
  end

  defp author_spec do
    StreamData.fixed_map(%{
      attrs: author_attrs(),
      posts: StreamData.list_of(row_attrs(), max_length: 100)
    })
  end

  defp row_attrs do
    Ash.Generator.action_input(TestPost, :create, post_input_overrides())
  end

  defp update_attrs do
    Ash.Generator.action_input(TestPost, :update, post_input_overrides())
  end

  defp author_attrs do
    Ash.Generator.action_input(TestAuthor, :create, %{
      name: StreamData.member_of(@author_names)
    })
  end

  defp post_input_overrides do
    %{
      name: StreamData.member_of(@names),
      age: StreamData.member_of(@ages),
      score: StreamData.member_of(@scores),
      published_at: StreamData.member_of(@dates)
    }
  end

  defp replay(resource, ops) do
    Enum.map(ops, &apply_op(resource, &1))
  end

  defp apply_op(resource, {:create, attrs}) do
    row =
      resource
      |> Ash.Changeset.for_create(:create, attrs)
      |> Ash.create!()

    {:create, normalise_row(row, @fields)}
  end

  defp apply_op(resource, {:update_by_name, name, attrs}) do
    rows =
      resource
      |> Ash.Query.filter(name == ^name)
      |> Ash.read!()

    updated =
      Enum.map(rows, fn row ->
        row
        |> Ash.Changeset.for_update(:update, attrs)
        |> Ash.update!()
      end)

    {:update_by_name, name, normalise_rows(updated, @fields)}
  end

  defp apply_op(resource, {:update_by_filter, statement, attrs}) do
    rows =
      resource
      |> read_query(statement, @fields)
      |> Ash.read!()

    updated =
      Enum.map(rows, fn row ->
        row
        |> Ash.Changeset.for_update(:update, attrs)
        |> Ash.update!()
      end)

    {:update_by_filter, statement, normalise_rows(updated, @fields)}
  end

  defp apply_op(resource, {:destroy_by_name, name}) do
    rows =
      resource
      |> Ash.Query.filter(name == ^name)
      |> Ash.read!()

    Enum.each(rows, &Ash.destroy!/1)

    {:destroy_by_name, name, length(rows)}
  end

  defp apply_op(resource, {:destroy_by_filter, statement}) do
    rows =
      resource
      |> read_query(statement, @fields)
      |> Ash.read!()

    Enum.each(rows, &Ash.destroy!/1)

    {:destroy_by_filter, statement, normalise_rows(rows, @fields)}
  end

  defp apply_op(resource, {:read_twice, statement, select}) do
    query = read_query(resource, statement, select)

    first = Ash.read!(query)
    second = Ash.read!(query)

    {:read_twice, statement, select, normalise_rows(first, select),
     normalise_rows(second, select)}
  end

  defp apply_op(resource, {:read_calc_twice, statement, select}) do
    query =
      resource
      |> read_query(statement, select)
      |> Ash.Query.load(:adult?)

    first = Ash.read!(query)
    second = Ash.read!(query)
    loaded_fields = Enum.uniq(select ++ [:adult?])

    {:read_calc_twice, statement, select, normalise_rows(first, loaded_fields),
     normalise_rows(second, loaded_fields)}
  end

  defp apply_op(resource, {:read_page_twice, statement, shape}) do
    query =
      resource
      |> read_query(statement, shape.select)
      |> Ash.Query.sort(shape.sort)
      |> Ash.Query.limit(shape.limit)
      |> Ash.Query.offset(shape.offset)

    first = Ash.read!(query)
    second = Ash.read!(query)

    {:read_page_twice, statement, shape, normalise_rows(first, shape.select),
     normalise_rows(second, shape.select)}
  end

  defp read_query(resource, statement, select) do
    filter = Ash.Filter.parse!(resource, statement)

    resource
    |> Ash.Query.do_filter(filter)
    |> Ash.Query.select(select)
  end

  defp normalise_rows(rows, fields) do
    rows
    |> Enum.map(&normalise_row(&1, fields))
    |> Enum.sort()
  end

  defp normalise_row(row, fields) do
    Map.new(fields, &{&1, Map.get(row, &1)})
  end

  defp seed_rows!(resource, rows) do
    Enum.each(rows, fn attrs ->
      resource
      |> Ash.Changeset.for_create(:create, attrs)
      |> Ash.create!()
    end)
  end

  defp seed_authors!(author_resource, post_resource, authors) do
    Enum.each(authors, fn %{attrs: attrs, posts: posts} ->
      author =
        author_resource
        |> Ash.Changeset.for_create(:create, attrs)
        |> Ash.create!()

      Enum.each(posts, fn attrs ->
        post_resource
        |> Ash.Changeset.for_create(:create, Map.put(attrs, :author_id, author.id))
        |> Ash.create!()
      end)
    end)
  end

  defp aggregate_reads(author_resource, post_resource) do
    # Warm both parent and child paths so the MDL side exercises folded cached aggregates too.
    author_resource |> Ash.read!()
    post_resource |> Ash.read!()

    query = Ash.Query.load(author_resource, [:post_count, :adult_post_count])

    first = Ash.read!(query)
    second = Ash.read!(query)

    {normalise_rows(first, [:name, :post_count, :adult_post_count]),
     normalise_rows(second, [:name, :post_count, :adult_post_count])}
  end

  defp reset_store! do
    AshMultiDatalayer.TestSupport.reset!(TestAuthor)
    AshMultiDatalayer.TestSupport.reset!(TestPost)
    Ash.DataLayer.Ets.stop(TestAuthor)
    Ash.DataLayer.Ets.stop(TestPost)

    MirrorPost
    |> Ash.read!()
    |> Enum.each(&Ash.destroy!/1)

    MirrorAuthor
    |> Ash.read!()
    |> Enum.each(&Ash.destroy!/1)
  end
end
