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
  alias AshMultiDatalayer.TenantKey
  alias AshMultiDatalayer.Telemetry

  @doc """
  Whether a ledger entry must be dropped for a row change.

  `row_before`/`row_after` are records (or `nil`: creates have no before,
  destroys no after). Conservative: an `:unknown` evaluation on either side
  drops the entry. Entries with no filter (universal coverage) match every
  row.
  """
  @spec should_drop?(Entry.t(), Ash.Resource.Record.t() | nil, Ash.Resource.Record.t() | nil) ::
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
  skipping the bump when nothing matched would reopen it.

  `tenant` is canonicalized via `TenantKey.canonical/2` (B3) before it's
  used as a ledger partition key — callers may pass any tenant
  representation. For a `global? true` resource (P4), the write also sweeps
  the complementary partition(s): a tenant-scoped write ALSO touches the
  unscoped partition (a nil-tenant read may have cached this row across
  every tenant); a genuinely unscoped write touches every partition
  currently holding entries (conservative — it may have been cached under
  any of them). See `sweep_partitions/2`.

  Also evicts the physical row from every earlier read layer (C4, fix
  direction 1) — see `evict_physical_row/3`, using the RAW (real,
  target-layer) tenant, never the partition key. This runs **regardless of
  the kill switch**: it is part of invalidation, and invalidation is
  already never skippable once the authoritative layer has committed (the
  kill switch only skips *propagation* — see `WriteDispatch`'s moduledoc).
  """
  @spec on_write(module(), term(), Ash.Resource.Record.t() | nil, Ash.Resource.Record.t() | nil) ::
          non_neg_integer()
  def on_write(resource, tenant, row_before, row_after) do
    evict_physical_row(resource, tenant, row_before)

    partition = TenantKey.canonical(resource, tenant)

    [partition | sweep_partitions(resource, partition)]
    |> Enum.reduce(0, fn p, total ->
      total + drop_for_partition(resource, p, row_before, row_after)
    end)
  end

  defp drop_for_partition(resource, tenant, row_before, row_after) do
    Coverage.bump_epoch(resource, tenant)

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

  # P4: 1:many sweep orchestration (B3's canonical function derives each
  # individual partition key; this only decides WHICH partitions a
  # `global? true` write must additionally touch — never re-derives a key).
  # Not `global?`: no sweep, the write's own partition is the only one a
  # read could ever have used.
  defp sweep_partitions(resource, partition) do
    if Ash.Resource.Info.multitenancy_global?(resource) do
      if TenantKey.unscoped?(partition) do
        resource |> Coverage.partitions() |> Enum.reject(&(&1 == partition))
      else
        [TenantKey.unscoped()]
      end
    else
      []
    end
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
  # (`AshMultiDatalayer.Orchestrator.ProvenCoverage`'s `maybe_backfill`/
  # `reconcile`) cleans up as defense in depth.
  #
  # Cost note: for a LOCAL write through `WriteDispatch`, this evict is
  # redundant churn — propagation re-upserts the fresh returned record
  # immediately after. Accepted for the single code path (pass-3 S3): with
  # a remote earlier layer this is a second network round trip per local
  # write; a future strategy with a different topology must revisit it.
  #
  # M-7 (doc-only by decision, whole-repo review): eviction here and
  # `WriteDispatch.propagate/5`'s re-upsert of the fresh record are two
  # separate steps, not one atomic swap — a reader landing in the window
  # between them sees the row PHYSICALLY ABSENT from an earlier layer, even
  # though it existed before this update and will exist again immediately
  # after. This is an absence ANOMALY (a state that never logically existed),
  # not staleness (a state that WAS true once) — the epoch/ledger protocol
  # this module implements guards against serving a stale value, not against
  # this kind of transient, self-healing miss. Revisit upsert-in-place for
  # updates (evict only on destroy/PK-change) only if this shows up in
  # practice; today's fix is documentation, not a behavior change.
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

            # L11: safe to normalize — this Enum.each result is discarded,
            # never returned to Ash (physical eviction runs synchronously
            # inside the authoritative write's own flow, but its outcome
            # never feeds back into that write's own result).
            {:error, :no_rollback, reason} ->
              log_eviction_failure(layer, resource, tenant, reason)

            {:error, reason} ->
              log_eviction_failure(layer, resource, tenant, reason)
          end
        end)
    end

    :ok
  end

  defp log_eviction_failure(layer, resource, tenant, reason) do
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

  @doc """
  Batched ghost eviction from a read-path reconcile pass (M-3). Reconcile
  physically finds rows in an earlier cache layer that a fresh source fetch
  did not return — but pre-fix, that destroy carried no epoch/ledger
  awareness at all, so a covering entry recorded concurrently by another
  reader (whose fetch legitimately included the row, postdating whatever
  write created it) survived pointing at a now-missing row: a lasting,
  silent missing-row cache hit (pass-2 C1's race).

  Reuses `on_write/4`'s exact machinery as a destroy-style invalidation for
  every ghost — `should_drop?(entry, ghost, nil)`, `row_after: nil` because
  each ghost is being evicted, not replaced — but batched: bump the epoch
  ONCE per reconcile pass (not once per ghost, pass-3 S1) and scan
  `Coverage.entries/2` ONCE, dropping any entry covering ANY ghost. A
  concurrent `Coverage.record/5` now sees the bumped epoch and aborts, exactly
  like every other cache mutation — closing the race `on_write/4` already
  closes for ordinary writes.

  Physical eviction of the ghost rows themselves stays in the caller (the
  read path already knows which specific layer each ghost was found on;
  `evict_physical_row/3` sweeps ALL earlier layers, which would be wrong
  here — a ghost on one cache layer says nothing about that row's validity
  on another).

  Known accepted consequence (pass-1 W3): the reconcile-initiating reader's
  OWN `Coverage.record/5` call also sees `epoch_moved?` (this bump) and skips
  recording — that reader's fetch predates its own reconcile's ledger
  surgery. Intentional and conservative: the next identical read is a clean
  miss that refetches and records fresh coverage.
  """
  @spec on_evict(module(), term(), [Ash.Resource.Record.t()]) :: non_neg_integer()
  def on_evict(_resource, _tenant, []), do: 0

  def on_evict(resource, tenant, ghosts) do
    Coverage.bump_epoch(resource, tenant)

    dropped =
      resource
      |> Coverage.entries(tenant)
      |> Enum.filter(fn entry -> Enum.any?(ghosts, &should_drop?(entry, &1, nil)) end)

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

  @doc """
  Drops **all** ledger entries for the resource+tenant. Used for writes with
  no reliable before-image (upserts): without knowing the previous row
  state, only clearing the partition is provably safe.

  Bumps the invalidation epoch first, unconditionally — same reasoning as
  `on_write/4`. `tenant` is canonicalized via `TenantKey.canonical/2` (B3),
  and the same `global?` sweep as `on_write/4` applies (P4).
  """
  @spec drop_all(module(), term()) :: non_neg_integer()
  def drop_all(resource, tenant) do
    partition = TenantKey.canonical(resource, tenant)

    [partition | sweep_partitions(resource, partition)]
    |> Enum.reduce(0, &(&2 + drop_all_for_partition(resource, &1)))
  end

  defp drop_all_for_partition(resource, tenant) do
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
