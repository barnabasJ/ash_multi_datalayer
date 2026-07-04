defmodule AshMultiDatalayer.SqlPassthrough do
  @moduledoc """
  Bridges an MDL-wrapped resource into an ash_sql relationship-aggregate
  subquery, so the aggregate can be computed as an in-database join.

  When a SQL parent (`AshPostgres` and friends) loads a relationship aggregate
  over an MDL-wrapped related resource, ash_sql builds the aggregate as a
  correlated in-DB subquery: it calls `Ash.Query.data_layer_query/1` on the
  related query expecting an `%Ecto.Query{}` to splice into a lateral join
  (`ash_sql/aggregate.ex`). MDL normally returns its routing struct, which
  ash_sql cannot splice — it crashes reaching for `__ash_bindings__`.

  ash_sql signals the subquery build by putting `parent_bindings` (the parent
  query's `__ash_bindings__`) and `start_bindings_at` into `context.data_layer`
  *before* the call, and MDL's `set_context/3` receives it. This module detects
  that signal and, when the related resource's own source of truth is a SQL
  layer in the *same repo* as the parent, builds and returns that layer's
  `%Ecto.Query{}` — passing the same context straight through, so the SQL
  layer's own binding / `parent_as` / `start_bindings_at` handshake lines up.
  ash_sql then splices the correlated join natively. See the
  relationship-aggregates ADR (option 3).

  A top-level read never carries `parent_bindings`, so this is inert outside an
  aggregate subquery. When the resource *does* participate in such a subquery
  but cannot be joined in-DB (no SQL source layer, or a different repo than the
  parent), it returns a clear error rather than letting ash_sql raise an opaque
  `KeyError` on the routing struct — MDL never fails silently.
  """

  alias AshMultiDatalayer.DataLayer.Info

  # `Ecto.Query` is only present when a SQL layer is configured; reference it
  # softly, exactly as `AshMultiDatalayer.Migration` references `AshPostgres`.
  @compile {:no_warn_undefined, [Ecto.Query]}

  @doc """
  If `context` is an ash_sql aggregate-subquery build, return
  `{:ok, ecto_query}` — the SQL source layer's query for `resource`, ready for
  ash_sql to splice into its lateral join. Otherwise `:not_a_subquery`.

  Returns `{:error, exception}` when `resource` participates in such a subquery
  but cannot be joined in-database (its source of truth is not a SQL layer of
  the parent's kind, or it is a different repo than the parent).
  """
  @spec build(Ash.Resource.t(), module(), map()) ::
          {:ok, term()} | :not_a_subquery | {:error, Exception.t()}
  def build(resource, domain, context) do
    case parent_bindings(context) do
      nil -> :not_a_subquery
      parent_bindings -> build_subquery(resource, domain, context, parent_bindings)
    end
  end

  @doc """
  The SQL source layer a passthrough query for `resource` targets — its source
  of truth (the last read layer). Used by the data layer's passthrough callback
  clauses to delegate the remaining query build.
  """
  @spec layer(Ash.Resource.t()) :: module()
  def layer(resource), do: List.last(Info.read_layer_modules(resource))

  defp parent_bindings(context) when is_map(context) do
    context |> Map.get(:data_layer, %{}) |> Map.get(:parent_bindings)
  end

  defp parent_bindings(_context), do: nil

  defp build_subquery(resource, domain, context, parent_bindings) do
    parent_sql = Map.get(parent_bindings, :sql_behaviour)
    parent_resource = Map.get(parent_bindings, :resource)

    case sql_query(layer(resource), resource, domain, context) do
      {:ok, %{__ash_bindings__: %{sql_behaviour: ^parent_sql}} = ecto_query}
      when not is_nil(parent_sql) ->
        if same_repo?(parent_sql, resource, parent_resource) do
          {:ok, ecto_query}
        else
          {:error, cross_repo_error(resource, parent_resource)}
        end

      _ ->
        {:error, no_sql_source_error(resource)}
    end
  end

  # Build the layer's native query with the SAME context, so a SQL layer runs
  # its `parent_bindings` / `start_bindings_at` handshake and numbers its
  # bindings to line up with the parent. A non-SQL layer yields a query without
  # `__ash_bindings__`, which fails the caller's match (→ a clear error).
  defp sql_query(layer, resource, domain, context) do
    query = Ash.DataLayer.resource_to_query(layer, resource, domain)

    if Code.ensure_loaded?(layer) and function_exported?(layer, :set_context, 3) do
      layer.set_context(resource, query, context)
    else
      {:ok, query}
    end
  end

  # Both resources resolve their repo through the parent's SQL behaviour, so
  # this is data-layer agnostic (no hard-coded `AshPostgres`).
  defp same_repo?(parent_sql, child_resource, parent_resource) do
    parent_sql.repo(child_resource, :read) == parent_sql.repo(parent_resource, :read)
  end

  defp cross_repo_error(resource, parent_resource) do
    ArgumentError.exception(
      "cannot compute a relationship aggregate on #{inspect(parent_resource)} over the " <>
        "multi-datalayer resource #{inspect(resource)} as an in-database join: its SQL " <>
        "source of truth is a different repo than the parent's. Fold it instead (leave " <>
        "the aggregate out of `sql_join_aggregates`) so it is computed from the related rows."
    )
  end

  defp no_sql_source_error(resource) do
    ArgumentError.exception(
      "cannot compute a relationship aggregate over the multi-datalayer resource " <>
        "#{inspect(resource)} as an in-database join: its source of truth is not a SQL " <>
        "layer of the parent's kind. Fold it instead (leave the aggregate out of " <>
        "`sql_join_aggregates`) so it is computed from the related rows."
    )
  end
end
