defmodule AshMultiDatalayer.ValueMerge do
  @moduledoc """
  Computed-value merge reads: serving a calc/aggregate-loading query from
  covered cache rows plus one narrow source-of-truth query for the computed
  values.

  Calculations and aggregates are computed by the source of truth and can
  never be reproduced from cached rows — but the *rows* often can. When the
  query's filter is covered, the rows are served by the cache layer and a
  single value query (`primary_key in [...]`, selecting only the PK plus the
  requested calculations/aggregates) fetches the computed values, which are
  merged into the cached records by primary key. The wire then carries only
  what the cache genuinely cannot know.

  Conservative fallbacks (never partial results):

    * composite primary keys aren't supported (no clean `in` filter) — the
      query falls through whole
    * a cached row with no source counterpart means the cache is stale for
      this read — the merge is abandoned and the query falls through whole
    * a failing value query fails the read (fail-fast, like any read-path
      layer error)
  """

  alias AshMultiDatalayer.DataLayer.Query
  alias AshMultiDatalayer.Delegate

  @doc "Whether merge reads are possible for this resource (single-attribute PK)."
  @spec mergeable?(module()) :: boolean()
  def mergeable?(resource) do
    match?([_], Ash.Resource.Info.primary_key(resource))
  end

  @doc "The query with its computed loads stripped — the cache-servable part."
  @spec row_query(Query.t() | struct()) :: Query.t() | struct()
  def row_query(%Query{} = query), do: %{query | calculations: [], aggregates: []}

  @doc """
  Fetches the query's calculations/aggregates for `rows` from `source_layer`
  and merges them in, preserving row order. Returns `{:ok, merged}`,
  `:stale_cache` when a row has no source counterpart, or `{:error, term}`.
  """
  @spec merge(Query.t() | struct(), [Ash.Resource.record()], module(), module()) ::
          {:ok, [Ash.Resource.record()]} | :stale_cache | {:error, term()}
  def merge(_query, [], _resource, _source_layer), do: {:ok, []}

  def merge(%Query{} = query, rows, resource, source_layer) do
    [pk] = Ash.Resource.Info.primary_key(resource)
    pk_values = Enum.map(rows, &Map.fetch!(&1, pk))

    value_query = %Query{
      resource: resource,
      domain: query.domain,
      tenant: query.tenant,
      context: query.context,
      filter: Ash.Filter.parse!(resource, [{pk, [in: pk_values]}]),
      select: [pk],
      calculations: query.calculations,
      aggregates: query.aggregates
    }

    with {:ok, value_rows} <- Delegate.run_on_layer(value_query, source_layer) do
      by_pk = Map.new(value_rows, &{Map.fetch!(&1, pk), &1})

      rows
      |> Enum.reduce_while([], fn row, acc ->
        case Map.fetch(by_pk, Map.fetch!(row, pk)) do
          {:ok, source} -> {:cont, [copy_computed(row, source, query) | acc]}
          :error -> {:halt, :stale_cache}
        end
      end)
      |> case do
        :stale_cache -> :stale_cache
        merged -> {:ok, Enum.reverse(merged)}
      end
    end
  end

  # Computed values land either on a loaded field (load: set) or in the
  # record's calculations/aggregates maps — mirror wherever the source layer
  # placed them.
  defp copy_computed(row, source, %Query{} = query) do
    row =
      Enum.reduce(query.aggregates, row, fn aggregate, acc ->
        copy_value(acc, source, aggregate.load, :aggregates, aggregate.name)
      end)

    Enum.reduce(query.calculations, row, fn {calculation, _expression}, acc ->
      copy_value(acc, source, calculation.load, :calculations, calculation.name)
    end)
  end

  defp copy_value(row, source, nil, map_key, name) do
    value = source |> Map.get(map_key, %{}) |> Map.get(name)
    Map.update!(row, map_key, &Map.put(&1, name, value))
  end

  defp copy_value(row, source, load_field, _map_key, _name) do
    Map.put(row, load_field, Map.get(source, load_field))
  end
end
