defmodule AshMultiDatalayer.Backfill do
  @moduledoc """
  Upserts records into cache layers — shared by the read path (backfilling
  fall-through results) and the write path (propagating the authoritative
  layer's returned record).

  Records are always **loaded structs returned by a lower layer**. The
  written field set comes from the `:fields` option; without it, ALL
  resource attributes are force-changed — including `%Ash.NotLoaded{}`
  sentinels on a partially-selected record — so callers upserting records
  from a narrower select MUST pass `:fields` (the write path does; see
  `AshMultiDatalayer.Orchestrator.LocalOutbox.Write`). The caller's original
  changeset is never re-run — server/database-computed fields exist only on
  the returned record (FR3.5).
  """

  @doc """
  Upserts `records` into every layer in `layers`, in order. Returns `:ok`
  only if every upsert succeeded; `{:error, layer, reason}` aborts at the
  first failure (callers must then skip coverage recording).
  """
  @spec upsert_records([module()], module(), [Ash.Resource.Record.t()], keyword()) ::
          :ok | {:error, module(), term()}
  def upsert_records(layers, resource, records, opts) do
    Enum.reduce_while(layers, :ok, fn layer, :ok ->
      records
      |> Enum.reduce_while(:ok, fn record, :ok ->
        case upsert_record(layer, resource, record, opts) do
          {:ok, _record} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, layer, reason}}
      end
    end)
  end

  @doc """
  Primary-key upserts one returned record into a layer. `opts`:

    * `:tenant` — the operation's tenant
    * `:domain` — the resource's domain
    * `:fields` — the fields to write (defaults to ALL resource attributes,
      which writes `%Ash.NotLoaded{}` sentinels for unselected fields — pass
      this explicitly unless the record is fully loaded); the primary key is
      always included
  """
  @spec upsert_record(module(), module(), Ash.Resource.Record.t(), keyword()) ::
          {:ok, Ash.Resource.Record.t()} | {:error, term()}
  def upsert_record(layer, resource, record, opts) do
    primary_key = Ash.Resource.Info.primary_key(resource)
    tenant = opts[:tenant]

    fields =
      (opts[:fields] || default_fields(resource, record))
      |> MapSet.new()
      |> MapSet.union(MapSet.new(primary_key))
      |> Enum.to_list()

    changeset =
      resource
      |> Ash.Changeset.new()
      |> Ash.Changeset.force_change_attributes(Map.take(record, fields))
      |> maybe_set_tenant(tenant)
      |> Map.put(:domain, opts[:domain])
      |> Ash.Changeset.set_context(
        AshMultiDatalayer.RemoteContext.merge(%{
          private: %{
            upsert_fields: fields,
            touch_update_defaults?: false,
            tenant: tenant
          }
        })
      )

    run_layer_upsert(layer, resource, changeset, primary_key)
    |> normalize_result()
  end

  @doc """
  Deletes a record (by primary key) from a layer. A row that's already
  absent is a success.
  """
  @spec destroy_record(module(), module(), Ash.Resource.Record.t(), keyword()) ::
          :ok | {:error, term()}
  def destroy_record(layer, resource, record, opts) do
    tenant = opts[:tenant]

    changeset =
      resource
      |> Ash.Changeset.new()
      |> maybe_set_tenant(tenant)
      |> Map.merge(%{
        data: record,
        domain: opts[:domain]
      })
      |> Ash.Changeset.set_context(
        AshMultiDatalayer.RemoteContext.merge(%{private: %{tenant: tenant}})
      )

    case layer.destroy(resource, changeset) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, :no_rollback, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_set_tenant(changeset, nil), do: changeset
  defp maybe_set_tenant(changeset, tenant), do: Ash.Changeset.set_tenant(changeset, tenant)

  # Mirrors Ash.DataLayer.upsert/4's arity dispatch for an explicitly delegated layer.
  defp run_layer_upsert(layer, resource, changeset, keys) do
    changeset = %{changeset | tenant: changeset.to_tenant}

    if Code.ensure_loaded?(layer) and function_exported?(layer, :upsert, 4) do
      Ash.DataLayer.run_upsert(layer, resource, changeset, keys, nil)
    else
      Ash.DataLayer.run_upsert(layer, resource, changeset, keys)
    end
  end

  defp normalize_result({:error, :no_rollback, reason}), do: {:error, reason}
  defp normalize_result(other), do: other

  defp default_fields(resource, record) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.map(& &1.name)
    |> Enum.filter(&loaded?(Map.get(record, &1)))
  end

  defp loaded?(%Ash.NotLoaded{}), do: false
  defp loaded?(_), do: true
end
