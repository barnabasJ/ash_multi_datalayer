defmodule AshMultiDatalayer.Coverage.Invalidation do
  @moduledoc """
  Row-aware coverage invalidation.

  After a successful authoritative write, every ledger entry whose filter
  matches the changed row — in its before **or** after state — is dropped;
  unrelated entries survive, preserving cache hit rate under write load.
  Matching uses `Ash.Filter.Runtime.do_match/6`, the same evaluator data
  layers use at read time, with `unknown_on_unknown_refs?: true` so any
  unresolvable reference drops the entry conservatively.

  This runs **before** the written record is propagated into earlier layers
  (FR3.6): if that propagation then fails, the covering entries are already
  gone, so the failure degrades to a coverage miss — never a stale read.

  `on_write/4` also upholds MDL's physical invariant itself (C4): dropping
  ledger entries alone leaves the destroyed/pre-update physical row sitting
  in earlier layers, and a later re-covering read would resurrect it as
  live. See `evict_physical_row/3` below.
  """

  require Logger

  alias AshMultiDatalayer.Backfill
  alias AshMultiDatalayer.Coverage
  alias AshMultiDatalayer.Coverage.Entry
  alias AshMultiDatalayer.DataLayer.Info
  alias AshMultiDatalayer.Telemetry

  @doc """
  Whether a ledger entry must be dropped for a row change.

  `row_before`/`row_after` are records (or `nil`: creates have no before,
  destroys no after). Conservative: an `:unknown` evaluation on either side
  drops the entry. Entries with no filter (universal coverage) match every
  row.
  """
  @spec should_drop?(Entry.t(), Ash.Resource.record() | nil, Ash.Resource.record() | nil) ::
          boolean()
  def should_drop?(%Entry{filter: nil}, row_before, row_after) do
    not (is_nil(row_before) and is_nil(row_after))
  end

  def should_drop?(%Entry{filter: filter}, row_before, row_after) do
    matches_or_unknown?(filter, row_before) or matches_or_unknown?(filter, row_after)
  end

  defp matches_or_unknown?(_filter, nil), do: false

  defp matches_or_unknown?(filter, row) do
    # Ash keeps records on TRUTHY results, not `== true` — mirror that.
    case Ash.Filter.Runtime.do_match(row, filter, nil, nil, true) do
      {:ok, falsy} when falsy in [false, nil] -> false
      {:ok, _truthy} -> true
      :unknown -> true
      {:error, _} -> true
    end
  rescue
    # An evaluator crash counts as unknown: drop conservatively.
    _ -> true
  end

  @doc """
  Drops every ledger entry (for the resource+tenant) matching the changed
  row, emitting `[:ash_multi_datalayer, :ledger, :invalidated]` with the
  dropped count. Returns the count.

  Bumps the invalidation epoch first, **unconditionally, including
  zero-drop writes** — the C3 race this closes is precisely a write against
  a ledger with nothing to drop for Q racing an in-flight miss for Q;
  skipping the bump when nothing matched would reopen it. Only the
  partition this write touches is bumped (the tenant, or `:__global__` for
  a nil tenant) — a cross-partition sweep for `global?` multitenancy is M6,
  out of scope here.

  Also evicts the physical row from every earlier read layer (C4, fix
  direction 1) — see `evict_physical_row/3`. This runs **regardless of the
  kill switch**: it is part of invalidation, and invalidation is already
  never skippable once the authoritative layer has committed (the kill
  switch only skips *propagation* — see `WriteDispatch`'s moduledoc).
  """
  @spec on_write(module(), term(), Ash.Resource.record() | nil, Ash.Resource.record() | nil) ::
          non_neg_integer()
  def on_write(resource, tenant, row_before, row_after) do
    Coverage.bump_epoch(resource, tenant)
    evict_physical_row(resource, tenant, row_before)

    dropped =
      resource
      |> Coverage.entries(tenant)
      |> Enum.filter(&should_drop?(&1, row_before, row_after))

    Enum.each(dropped, &Coverage.drop(resource, tenant, &1.id))

    count = length(dropped)

    if count > 0 do
      Telemetry.ledger(:invalidated, resource, tenant, %{
        count: count,
        ledger_size: Coverage.size(resource, tenant)
      })
    end

    count
  end

  # Removes the row from every earlier read layer, by the BEFORE-image's
  # primary key — the addendum's fix direction 1. A create (`row_before ==
  # nil`) has nothing to evict. For a destroy OR an update, the before-image
  # PK is always the stale row: a destroy's row is gone outright; an
  # update's before-PK row is stale even when the update changed the PK
  # itself (the after-PK row heals via ordinary upsert/refetch — evicting it
  # here would be wrong). PK-only eviction is deliberate: it is safe even
  # with a partial notification payload (an external caller of `on_write/4`
  # or `AshMultiDatalayer.forget!/3` may not have full row data), where
  # upserting a possibly-partial after-image would risk writing
  # `%Ash.NotLoaded{}` sentinels over good values.
  #
  # Failure is swallowed (warn + telemetry), mirroring
  # `WriteDispatch.propagate/5`'s posture: `on_write/4` runs inline after the
  # authoritative write already committed (the local path) or inside an
  # external notification handler — neither may crash. The residue of a
  # failed evict (a surviving ghost row, with its covering entries already
  # dropped above) is exactly what the read-path reconcile pass
  # (`AshMultiDatalayer.DataLayer`'s `maybe_backfill`) cleans up as defense
  # in depth.
  #
  # Cost note: for a LOCAL write through `WriteDispatch`, this evict is
  # redundant churn — propagation re-upserts the fresh returned record
  # immediately after. Accepted for the single code path (pass-3 S3): with
  # a remote earlier layer this is a second network round trip per local
  # write; a future strategy with a different topology must revisit it.
  defp evict_physical_row(_resource, _tenant, nil), do: :ok

  defp evict_physical_row(resource, tenant, row_before) do
    case Enum.drop(Info.read_layer_modules(resource), -1) do
      [] ->
        :ok

      earlier_layers ->
        opts = [tenant: tenant, domain: Ash.Resource.Info.domain(resource)]

        Enum.each(earlier_layers, fn layer ->
          case Backfill.destroy_record(layer, resource, row_before, opts) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "ash_multi_datalayer physical eviction on #{inspect(layer)} failed for " <>
                  "#{inspect(resource)}: #{inspect(reason)} — a surviving ghost row is " <>
                  "cleaned up by the next covering read's reconcile pass"
              )

              Telemetry.ledger(:evict_failed, resource, tenant, %{}, %{
                layer: layer,
                reason: reason
              })
          end
        end)
    end

    :ok
  end

  @doc """
  Drops **all** ledger entries for the resource+tenant. Used for writes with
  no reliable before-image (upserts): without knowing the previous row
  state, only clearing the partition is provably safe.

  Bumps the invalidation epoch first, unconditionally — same reasoning as
  `on_write/4`.
  """
  @spec drop_all(module(), term()) :: non_neg_integer()
  def drop_all(resource, tenant) do
    Coverage.bump_epoch(resource, tenant)

    entries = Coverage.entries(resource, tenant)
    Enum.each(entries, &Coverage.drop(resource, tenant, &1.id))

    count = length(entries)

    if count > 0 do
      Telemetry.ledger(:invalidated, resource, tenant, %{count: count, ledger_size: 0})
    end

    count
  end
end
