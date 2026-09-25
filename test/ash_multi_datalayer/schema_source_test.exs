defmodule AshMultiDatalayer.SchemaSourceTest do
  @moduledoc """
  Regression: `AshMultiDatalayer.DataLayer.source/1` must resolve the real
  SQL table even when the orchestrator's `authority/1` layer isn't SQL-backed
  (ProvenCoverage with a SQL *cache* fronting a non-SQL source of truth).
  """
  use ExUnit.Case, async: true

  alias AshMultiDatalayer.Test.SchemaSource.Widget

  test "resolves the SQL cache layer's table, not the non-SQL authority layer's empty answer" do
    assert Ash.DataLayer.source(Widget) == "schema_source_widgets"
  end

  test "Ecto.Query.from/2 (what a Queryable-based upsert needs) resolves the real table" do
    require Ecto.Query
    query = Ecto.Query.from(row in Widget, as: ^0)
    assert {"schema_source_widgets", Widget} = query.from.source
  end
end
