defmodule AshMultiDatalayer.Backfill do
  @moduledoc """
  Upserts records into cache layers — shared by the read path (backfilling
  fall-through results) and the write path (propagating the authoritative
  layer's returned record).

  Records are always **loaded structs returned by a lower layer**; only
  their loaded fields (plus primary key) are force-changed, so a fuller
  cached row is never clobbered by a narrower select. The caller's original
  changeset is never re-run — server/database-computed fields exist only on
  the returned record (FR3.5).
  """

  require Logger

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
    * `:fields` — the fields to write (defaults to the record's non-`nil`
      loaded attributes); the primary key is always included
  """
  @spec upsert_record(module(), module(), Ash.Resource.Record.t(), keyword()) ::
          {:ok, Ash.Resource.Record.t()} | {:error, term()}
  def upsert_record(layer, resource, record, opts) do
    primary_key = Ash.Resource.Info.primary_key(resource)
    tenant = opts[:tenant]

    fields =
      (opts[:fields] || default_fields(resource))
      |> MapSet.new()
      |> MapSet.union(MapSet.new(primary_key))
      |> Enum.to_list()

    changeset =
      resource
      |> Ash.Changeset.new()
      |> Ash.Changeset.force_change_attributes(Map.take(record, fields))
      |> Map.merge(%{
        domain: opts[:domain],
        tenant: tenant,
        to_tenant: tenant
      })
      |> Ash.Changeset.set_context(%{
        private: %{
          upsert_fields: fields,
          touch_update_defaults?: false,
          tenant: tenant
        }
      })

    Ash.DataLayer.run_upsert(layer, resource, changeset, primary_key)
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
      |> Map.merge(%{
        data: record,
        domain: opts[:domain],
        tenant: tenant,
        to_tenant: tenant
      })
      |> Ash.Changeset.set_context(%{private: %{tenant: tenant}})

    case layer.destroy(resource, changeset) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_fields(resource) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.map(& &1.name)
  end
end
