defmodule AshMultiDatalayer.Orchestrator.LocalOutbox do
  @moduledoc """
  Local-authoritative orchestration strategy: the first `write_order` layer is a
  complete, authoritative local copy; every later layer is an **asynchronous
  replication target** drained through an ordered outbox (an app-owned Ash
  resource on Oban). Reads are served entirely from the local layer and never
  fall through. See the LocalOutbox RFC — this module is its implementation.

  DSL:

      multi_data_layer do
        orchestrator {AshMultiDatalayer.Orchestrator.LocalOutbox,
          outbox_resource: TodoClient.Sync.OutboxEntry,
          conflict_detection: :off,          # :off | {:stale_check, :updated_at}
          hydrate: :if_empty}                # :if_empty | :on_start | :manual

        layer :local, AshSqlite.DataLayer
        layer :remote, AshRemote.DataLayer
        read_order [:local]                  # verifier-enforced: exactly the local layer
        write_order [:local, :remote]        # hd = authority, rest = targets
      end

  The public resolution/control API (`await/2`, `status/1`, `pending/2`,
  `parked/2`, `retry/1`, `discard/1`, `discard_local/1`, `force/1`, `rebase/2`,
  `pause_sync/1`/`resume_sync/1`/`sync_paused?/1`, `refresh/3`, `hydrate/2`) lives
  in `AshMultiDatalayer.Orchestrator.LocalOutbox.Api` and is re-exported here.
  """
  @behaviour AshMultiDatalayer.Orchestrator

  alias AshMultiDatalayer.DataLayer.Info
  alias AshMultiDatalayer.DataLayer.Query
  alias AshMultiDatalayer.Delegate
  alias AshMultiDatalayer.Orchestrator.LocalOutbox.Api
  alias AshMultiDatalayer.Orchestrator.LocalOutbox.Write

  # --- config resolution -------------------------------------------------

  @doc false
  def opts(resource) do
    {__MODULE__, opts} = Info.orchestrator(resource)
    opts
  end

  @doc "The authoritative local layer module (hd of write_order)."
  @spec local_layer(Ash.Resource.t()) :: module()
  def local_layer(resource), do: hd(Info.write_layer_modules(resource))

  @doc "The asynchronous replication target layer names (tl of write_order)."
  @spec targets(Ash.Resource.t()) :: [atom()]
  def targets(resource), do: tl(Info.write_order(resource))

  @doc "The target layer module for a target name."
  @spec target_layer(Ash.Resource.t(), atom()) :: module()
  def target_layer(resource, target), do: Info.layer!(resource, target)

  @doc "The app-owned outbox entry resource backing this strategy."
  @spec outbox_resource(Ash.Resource.t()) :: module()
  def outbox_resource(resource), do: Keyword.fetch!(opts(resource), :outbox_resource)

  @doc "Conflict detection mode: `:off` (default) or `{:stale_check, field}`."
  @spec conflict_detection(Ash.Resource.t()) :: :off | {:stale_check, atom()}
  def conflict_detection(resource), do: Keyword.get(opts(resource), :conflict_detection, :off)

  @doc "Hydration mode: `:if_empty` (default) | `:on_start` | `:manual`."
  @spec hydrate_mode(Ash.Resource.t()) :: :if_empty | :on_start | :manual
  def hydrate_mode(resource), do: Keyword.get(opts(resource), :hydrate, :if_empty)

  # --- structural answers ------------------------------------------------

  # The authority for BOTH reads and transactions is the local layer — the
  # inverted authority that defines this strategy.
  @impl true
  def authority(resource), do: local_layer(resource)

  @impl true
  def transaction_layer(resource), do: local_layer(resource)

  # Everything read-shaped delegates wholesale to the local layer: it is
  # authoritative and complete, so aggregates/distinct/joins/select answer
  # whatever it answers. Write features are the local layer's too. The only
  # hardcoded `false`s are the orchestration-bypass guards — bulk/atomic/query
  # mutations would touch the local layer without enqueueing outbox entries
  # (silent divergence), even where the local layer supports them (ash_sqlite
  # advertises `update_query`). See the RFC's `can?` section.
  @impl true
  def can?(_resource, :update_query), do: false
  def can?(_resource, :destroy_query), do: false
  def can?(_resource, {:atomic, _}), do: false
  def can?(_resource, :bulk_create), do: false
  def can?(_resource, {:bulk_create, _}), do: false
  def can?(_resource, :combine), do: false
  def can?(_resource, {:combine, _}), do: false

  def can?(resource, feature) do
    layer = local_layer(resource)

    if Code.ensure_loaded?(layer) and function_exported?(layer, :can?, 2) do
      layer.can?(resource, feature)
    else
      :default
    end
  end

  @doc false
  # LocalOutbox never participates in ash_sql aggregate-subquery passthrough:
  # its local layer is a complete authoritative copy, computed in place.
  def sql_passthrough?(_resource), do: false

  # --- read path ---------------------------------------------------------

  @impl true
  def read(%Query{} = query, resource) do
    Delegate.run_on_layer(query, local_layer(resource))
  end

  @impl true
  def run_aggregate_query(%Query{} = query, aggregates, resource) do
    layer = local_layer(resource)

    with {:ok, layer_query} <- Delegate.to_layer_query(query, layer) do
      Ash.DataLayer.run_aggregate_query(layer, layer_query, aggregates, resource)
    end
  end

  # --- write path (delegated to the Write helper) ------------------------

  @impl true
  def create(resource, changeset), do: Write.run(resource, changeset, :create)

  @impl true
  def update(resource, changeset), do: Write.run(resource, changeset, :update)

  @impl true
  def destroy(resource, changeset), do: Write.run(resource, changeset, :destroy)

  @impl true
  def upsert(resource, changeset, keys, identity),
    do: Write.run(resource, changeset, {:upsert, keys, identity})

  # --- lifecycle ---------------------------------------------------------

  @impl true
  def validate_opts(dsl_or_resource, opts) do
    cond do
      is_nil(opts[:outbox_resource]) ->
        {:error, "LocalOutbox requires an `outbox_resource:` option."}

      not Enum.member?([:if_empty, :on_start, :manual], Keyword.get(opts, :hydrate, :if_empty)) ->
        {:error, "LocalOutbox `hydrate:` must be :if_empty, :on_start, or :manual."}

      not valid_conflict_detection?(Keyword.get(opts, :conflict_detection, :off)) ->
        {:error, "LocalOutbox `conflict_detection:` must be :off or {:stale_check, field}."}

      not oban_loaded?() ->
        {:error, "LocalOutbox requires oban + ash_oban (optional deps) to be available."}

      true ->
        validate_shape(dsl_or_resource, opts)
    end
  end

  defp valid_conflict_detection?(:off), do: true
  defp valid_conflict_detection?({:stale_check, field}) when is_atom(field), do: true
  defp valid_conflict_detection?(_), do: false

  defp oban_loaded?, do: Code.ensure_loaded?(Oban) and Code.ensure_loaded?(AshOban)

  defp validate_shape(dsl_or_resource, opts) do
    read_order = Info.read_order(dsl_or_resource)
    write_order = Info.write_order(dsl_or_resource)

    cond do
      length(read_order) != 1 ->
        {:error,
         "LocalOutbox requires `read_order` to be exactly the local layer; got #{inspect(read_order)}."}

      write_order == [] or hd(write_order) != hd(read_order) ->
        {:error,
         "LocalOutbox requires `hd(write_order)` (the authority) to equal the single read layer."}

      length(write_order) < 2 ->
        {:error, "LocalOutbox requires at least one replication target in `write_order`."}

      true ->
        validate_co_commit(dsl_or_resource, opts)
    end
  end

  # M-4: an async write with no co-commit repo commits the local write
  # durably and then raises (instead of returning `{:error, _}`) when the
  # outbox enqueue fails — a silently orphaned local write. Reject the
  # config at compile time rather than let it degrade at the first failure.
  defp validate_co_commit(dsl_or_resource, opts) do
    local_layer = hd(Info.write_layer_modules(dsl_or_resource))
    outbox = Keyword.fetch!(opts, :outbox_resource)

    case Code.ensure_compiled(outbox) do
      {:module, ^outbox} ->
        if AshMultiDatalayer.Orchestrator.LocalOutbox.Write.co_commit_repo(
             dsl_or_resource,
             local_layer,
             outbox
           ) do
          :ok
        else
          {:error,
           "LocalOutbox requires the local layer (#{inspect(local_layer)}) and " <>
             "`outbox_resource:` (#{inspect(outbox)}) to share a co-commit Ecto repo — " <>
             "an async write's local commit and outbox enqueue must be one transaction, or a " <>
             "failed enqueue silently orphans the local write. Configure both on the same repo."}
        end

      {:error, reason} ->
        {:error,
         "LocalOutbox's `outbox_resource:` (#{inspect(outbox)}) could not be compiled/loaded " <>
           "(#{inspect(reason)})."}
    end
  end

  @impl true
  def child_specs(resources), do: Api.child_specs(resources)

  # --- inbound (Phase 4 refresh/reconcile) -------------------------------

  @impl true
  def handle_external_change(resource, notification),
    do: Api.handle_external_change(resource, notification)

  @impl true
  def handle_external_gap(resource, tenant), do: Api.handle_external_gap(resource, tenant)

  # --- public API re-exports --------------------------------------------

  defdelegate await(record_or_ref, opts \\ []), to: Api
  defdelegate status(record_or_ref), to: Api
  defdelegate pending(resource, tenant \\ nil), to: Api
  defdelegate parked(resource, tenant \\ nil), to: Api
  defdelegate retry(entry), to: Api
  defdelegate discard(entry), to: Api
  defdelegate discard_local(entry), to: Api
  defdelegate force(entry), to: Api
  defdelegate rebase(entry, changeset), to: Api
  defdelegate pause_sync(resource), to: Api
  defdelegate resume_sync(resource), to: Api
  defdelegate sync_paused?(resource), to: Api
  defdelegate refresh(resource, scope, tenant \\ nil), to: Api
  defdelegate hydrate(resource, tenant \\ nil), to: Api
end
