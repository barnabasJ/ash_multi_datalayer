defmodule AshMultiDatalayer.Orchestrator.LocalOutbox.Target do
  @moduledoc """
  Push/read helpers between a LocalOutbox host resource and a replication target
  layer — the same `Backfill`/`Delegate` mechanisms ProvenCoverage's propagation
  and reads use, so the strategy adds no new data-path primitive.
  """
  alias AshMultiDatalayer.Backfill
  alias AshMultiDatalayer.DataLayer.Query
  alias AshMultiDatalayer.Delegate
  alias AshMultiDatalayer.Orchestrator.LocalOutbox
  alias AshMultiDatalayer.Orchestrator.LocalOutbox.Snapshot

  @doc "PK-upsert `record` into `target` (a layer name). Optional `filter` guards a stale-check."
  def upsert(resource, target, record, opts \\ []) do
    layer = LocalOutbox.target_layer(resource, target)
    Backfill.upsert_record(layer, resource, record, opts)
  end

  @doc "PK-destroy `record` from `target`."
  def destroy(resource, target, record, opts \\ []) do
    layer = LocalOutbox.target_layer(resource, target)
    Backfill.destroy_record(layer, resource, record, opts)
  end

  @doc "Read the current row for a primary key from a layer (`:read`-shaped, side-effect-free)."
  def read_pk(resource, layer_name, record_pk, opts \\ []) do
    layer = LocalOutbox.target_layer(resource, layer_name)
    tenant = opts[:tenant]

    query = %Query{
      resource: resource,
      domain: opts[:domain] || Ash.Resource.Info.domain(resource),
      tenant: tenant,
      select: full_select(resource),
      context: AshMultiDatalayer.RemoteContext.resolve(),
      filter: pk_filter(resource, record_pk)
    }

    case Delegate.run_on_layer(query, layer) do
      {:ok, [row | _]} -> {:ok, row}
      {:ok, []} -> {:ok, nil}
      {:error, error} -> {:error, error}
    end
  end

  @doc "Read every row of `resource` from a layer (hydration/reconcile source)."
  def read_all(resource, layer_name, opts \\ []) do
    layer = LocalOutbox.target_layer(resource, layer_name)

    query = %Query{
      resource: resource,
      domain: opts[:domain] || Ash.Resource.Info.domain(resource),
      tenant: opts[:tenant],
      select: full_select(resource),
      context: AshMultiDatalayer.RemoteContext.resolve()
    }

    Delegate.run_on_layer(query, layer)
  end

  # A LocalOutbox read pulls the whole row (hydration writes it into the local
  # authority; the stale-check needs the conflict field). Layers that ignore
  # `select` (ETS) return full rows anyway; ones that honour it (AshRemote fetches
  # only the requested wire fields) would otherwise return the primary key alone.
  defp full_select(resource) do
    resource |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name)
  end

  @doc "Build a filter matching a record's primary key (from a string-keyed pk map)."
  def pk_filter(resource, record_pk) do
    keys = Ash.Resource.Info.primary_key(resource)

    filter_map =
      for key <- keys, into: %{} do
        {:ok, value} =
          Ash.Type.cast_input(
            Ash.Resource.Info.attribute(resource, key).type,
            record_pk[to_string(key)],
            []
          )

        {key, value}
      end

    Ash.Filter.parse!(resource, filter_map)
  end

  @doc "Rebuild the record a stored entry describes (payload for upsert, pk-only for destroy)."
  def record_from_entry(resource, %{payload: payload}) when is_map(payload),
    do: Snapshot.load(resource, payload)

  def record_from_entry(resource, %{record_pk: record_pk}),
    do: Snapshot.load(resource, record_pk)
end
