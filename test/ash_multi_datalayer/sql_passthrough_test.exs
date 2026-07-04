defmodule AshMultiDatalayer.SqlPassthroughTest do
  @moduledoc """
  Unit tests for the aggregate-subquery bridge: detection of ash_sql's
  `parent_bindings` signal, the same-repo SQL gate, and the loud error when a
  resource can't be joined. The end-to-end joins live in the integration matrix
  (`AggregateJoinsTest`).
  """
  use ExUnit.Case, async: true

  alias AshMultiDatalayer.SqlPassthrough
  alias AshMultiDatalayer.Test.Resources.{Domain, EtsPost, PgAuthor, TestPost}

  # ash_sql sets `context.data_layer.parent_bindings` (the parent query's
  # `__ash_bindings__`, carrying `sql_behaviour`) before asking a related
  # resource for its query.
  defp subquery_context(opts \\ []) do
    %{
      data_layer: %{
        parent_bindings: %{
          sql_behaviour: opts[:sql_behaviour] || AshPostgres.SqlImplementation,
          resource: opts[:parent] || PgAuthor
        },
        start_bindings_at: 0
      }
    }
  end

  test "returns :not_a_subquery outside an aggregate subquery" do
    assert SqlPassthrough.build(TestPost, Domain, %{}) == :not_a_subquery
    assert SqlPassthrough.build(TestPost, Domain, %{data_layer: %{}}) == :not_a_subquery
  end

  test "returns the SQL source layer's Ecto query for a same-repo SQL child" do
    assert {:ok, ecto} = SqlPassthrough.build(TestPost, Domain, subquery_context())
    # A real ash_sql query, ready for ash_sql to splice into its lateral join.
    assert ecto.__ash_bindings__.sql_behaviour == AshPostgres.SqlImplementation
  end

  test "errors clearly when the child has no matching SQL source — never a silent crash" do
    assert {:error, %ArgumentError{} = err} =
             SqlPassthrough.build(EtsPost, Domain, subquery_context())

    assert Exception.message(err) =~ "in-database join"
  end

  test "errors when the parent's SQL dialect does not match any of the child's read layers" do
    context = subquery_context(sql_behaviour: :some_other_sql_implementation)

    assert {:error, %ArgumentError{}} = SqlPassthrough.build(TestPost, Domain, context)
  end
end
