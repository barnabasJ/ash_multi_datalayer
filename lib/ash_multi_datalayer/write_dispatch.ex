defmodule AshMultiDatalayer.WriteDispatch do
  @moduledoc """
  Routes writes across `write_order`.

  Invariant (PRD FR3.5/FR3.6): when a write returns, every layer earlier in
  `read_order` than the authoritative layer either reflects the returned
  record or holds no coverage claiming it. Concretely, per write:

    1. **Authoritative write** to the first `write_order` layer — fail-fast:
       its error is returned verbatim; nothing else is touched.
    2. **Ledger invalidation** — before any cache write, so a later failure
       can never leave stale coverage behind.
    3. **Propagation** — the record the authoritative layer *returned* is
       primary-key-upserted into the remaining layers (never a re-run of the
       caller's changeset: authoritative-computed fields exist only on the
       returned record). A propagation failure is logged + telemetried but
       does not fail the operation — step 2 already degraded it to a miss.

  Kill-switch engaged: only the authoritative write happens; invalidation
  still runs (so re-enabling can't serve pre-switch coverage) — **including
  the physical eviction `Coverage.Invalidation.on_write/4` performs (C4)**,
  which is part of invalidation and therefore never skippable either;
  propagation (the upsert half of keeping earlier layers warm) is what's
  skipped.
  """

  require Logger

  alias AshMultiDatalayer.Backfill
  alias AshMultiDatalayer.Coverage
  alias AshMultiDatalayer.Coverage.Invalidation
  alias AshMultiDatalayer.DataLayer.Info
  alias AshMultiDatalayer.KillSwitch
  alias AshMultiDatalayer.Telemetry

  @spec create(module(), Ash.Changeset.t()) ::
          {:ok, Ash.Resource.record()} | {:error, term()}
  def create(resource, changeset) do
    dispatch(resource, changeset, :create, fn layer ->
      layer.create(resource, changeset)
    end)
  end

  @spec update(module(), Ash.Changeset.t()) ::
          {:ok, Ash.Resource.record()} | {:error, term()}
  def update(resource, changeset) do
    dispatch(resource, changeset, :update, fn layer ->
      layer.update(resource, changeset)
    end)
  end

  @spec upsert(module(), Ash.Changeset.t(), [atom()], Ash.Resource.Identity.t() | nil) ::
          {:ok, Ash.Resource.record()} | {:error, term()}
  def upsert(resource, changeset, keys, identity) do
    dispatch(resource, changeset, :upsert, fn layer ->
      case run_layer_upsert(layer, resource, changeset, keys, identity) do
        {:ok, {:upsert_skipped, _query, _callback} = skipped} -> {:ok, skipped}
        other -> other
      end
    end)
  end

  @spec destroy(module(), Ash.Changeset.t()) :: :ok | {:error, term()}
  def destroy(resource, changeset) do
    case dispatch(resource, changeset, :destroy, fn layer ->
           case layer.destroy(resource, changeset) do
             :ok -> {:ok, changeset.data}
             other -> other
           end
         end) do
      {:ok, _record} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp dispatch(resource, changeset, operation, authoritative_write) do
    [authoritative | rest] = Info.write_layer_modules(resource)
    started = System.monotonic_time()

    # L11: the authoritative write's result propagates all the way back to
    # Ash's own transaction machinery (this function IS the DataLayer
    # create/update/upsert/destroy callback) — a `{:error, :no_rollback,
    # reason}` here must reach Ash as the same 3-tuple, or Ash rolls back a
    # transaction the layer explicitly said to preserve. Only the
    # `{:ok, ...}`/plain-`{:error, _}` shapes get matched here; the
    # 3-tuple case falls through unnormalized.
    case authoritative_write.(authoritative) do
      # M1: an upsert_condition-skipped upsert wrote nothing — `record` here
      # is a `{:upsert_skipped, query, callback}` tuple, not a record.
      # Surface it unchanged — no invalidation/propagation for a write that
      # didn't happen.
      {:ok, {:upsert_skipped, _query, _callback} = skipped} ->
        {:ok, skipped}

      {:ok, record} ->
        # Ash carries the action's tenant on the changeset (and enforces it
        # for non-`global?` multitenant resources); a tenant-less write on a
        # `global?` resource is genuinely unscoped (nil) — invalidation's
        # partition sweep handles that conservatively.
        tenant = changeset.to_tenant
        dropped = invalidate(resource, tenant, changeset, operation, record)

        if KillSwitch.enabled?(resource) do
          propagate(rest, resource, changeset, operation, record, tenant)
        end

        Telemetry.write(
          :applied,
          resource,
          tenant,
          %{
            duration_us: Telemetry.duration_us(started),
            ledger_size: Coverage.size(resource, tenant)
          },
          %{operation: operation, dropped_count: dropped}
        )

        {:ok, record}

      {:error, :no_rollback, _reason} = error ->
        error

      {:error, _} = error ->
        error
    end
  end

  # Invalidation runs BEFORE propagation and is never skippable once the
  # authoritative layer has committed.
  defp invalidate(resource, tenant, changeset, operation, record) do
    case row_change(changeset, operation, record) do
      {row_before, row_after} ->
        Invalidation.on_write(resource, tenant, row_before, row_after)

      :no_before_image ->
        # Upserts have no reliable before-image; only a full drop is safe.
        Invalidation.drop_all(resource, tenant)
    end
  end

  defp row_change(_changeset, :create, record), do: {nil, record}
  defp row_change(changeset, :update, record), do: {changeset.data, record}
  defp row_change(changeset, :destroy, _record), do: {changeset.data, nil}
  defp row_change(_changeset, :upsert, _record), do: :no_before_image

  defp propagate(layers, resource, changeset, operation, record, tenant) do
    opts = [tenant: tenant, domain: changeset.domain]

    Enum.each(layers, fn layer ->
      result =
        case operation do
          :destroy -> Backfill.destroy_record(layer, resource, record, opts)
          _write -> propagate_upsert(layer, resource, record, opts)
        end

      # L11: safe to normalize — this result is only ever logged/telemetried
      # (Enum.each discards it, and the caller never binds propagate/6's
      # return value), never returned to Ash's transaction machinery. The
      # authoritative write above (never a secondary/cache layer) is the
      # only result on that path.
      case normalize_result(result) do
        :ok ->
          :ok

        {:ok, _record} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "ash_multi_datalayer write propagation to #{inspect(layer)} failed for " <>
              "#{inspect(resource)}: #{inspect(reason)} — coverage was already " <>
              "invalidated, so the next read falls through (miss, not staleness)"
          )

          Telemetry.write(:failed_at_layer, resource, tenant, %{}, %{
            operation: operation,
            layer: layer,
            reason: reason
          })
      end
    end)
  end

  # A skipped upsert leaves no record to propagate; the row is unchanged.
  defp propagate_upsert(_layer, _resource, {:upsert_skipped, _query, _callback}, _opts), do: :ok

  defp propagate_upsert(layer, resource, record, opts) do
    Backfill.upsert_record(layer, resource, record, opts)
  end

  defp normalize_result({:error, :no_rollback, reason}), do: {:error, reason}
  defp normalize_result(other), do: other

  # Mirrors Ash.DataLayer.upsert/4's arity dispatch for an explicitly delegated layer.
  defp run_layer_upsert(layer, resource, changeset, keys, identity) do
    changeset = %{changeset | tenant: changeset.to_tenant}

    if Code.ensure_loaded?(layer) and function_exported?(layer, :upsert, 4) do
      Ash.DataLayer.run_upsert(layer, resource, changeset, keys, identity)
    else
      Ash.DataLayer.run_upsert(layer, resource, changeset, keys)
    end
  end
end
