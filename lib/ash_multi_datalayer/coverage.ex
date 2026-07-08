defmodule AshMultiDatalayer.Coverage do
  @moduledoc """
  The coverage ledger: per-resource, tenant-partitioned records of which
  filters have been fully materialised into earlier layers.

  Storage is a named public ETS table per resource, owned by
  `AshMultiDatalayer.Coverage.TableOwner` and created lazily on first use.
  Rows are keyed `{tenant, entry_id}`; the tenant component is the operation's
  own (`Ash.ToTenant`-converted) tenant, or `nil` for untenanted entries,
  which form their own partition under the `nil` key.
  """

  require Logger

  alias AshMultiDatalayer.Coverage.{Complement, Entry, Implication, Normaliser, TableOwner}
  alias AshMultiDatalayer.DataLayer.Info
  alias AshMultiDatalayer.DataLayer.Query
  alias AshMultiDatalayer.Telemetry

  @doc """
  Ensures the resource's ledger table exists, lazily starting its owner.

  Returns `:ok`, or `{:error, :unavailable}` when `AshMultiDatalayer.Supervisor`
  is not running in the host application — in that case callers degrade to
  kill-switched behaviour (a performance bug, never a correctness bug), and a
  warning is logged once per node.
  """
  @spec ensure_table(module()) :: :ok | {:error, :unavailable}
  def ensure_table(resource) do
    if :ets.whereis(TableOwner.table_name(resource)) != :undefined do
      :ok
    else
      start_owner(resource)
    end
  end

  @doc "All ledger entries for a resource+tenant."
  @spec entries(module(), term()) :: [term()]
  def entries(resource, tenant) do
    table = TableOwner.table_name(resource)
    key = tenant

    :ets.select(table, [{{{key, :_}, :"$1"}, [], [:"$1"]}])
  rescue
    ArgumentError -> []
  end

  @doc """
  Every distinct tenant partition currently holding a ledger entry for
  `resource` (P4: the "sweep every partition" side of a `global? true`
  nil-tenant write). Excludes the epoch meta-keys (`{:__mdl_meta__, :epoch,
  _}`), which share the same table but are not entry keys.
  """
  @spec partitions(module()) :: [term()]
  def partitions(resource) do
    table = TableOwner.table_name(resource)

    :ets.select(table, [{{{:"$1", :_}, :_}, [], [:"$1"]}])
    |> Enum.reject(&(&1 == :__mdl_meta__))
    |> Enum.uniq()
  rescue
    ArgumentError -> []
  end

  @doc "Inserts a ledger entry (keyed by `entry.id`) for a resource+tenant."
  @spec insert(module(), term(), %{:id => term(), optional(any()) => any()}) :: :ok
  def insert(resource, tenant, entry) do
    table = TableOwner.table_name(resource)
    true = :ets.insert(table, {{tenant, entry.id}, entry})
    :ok
  rescue
    # L12 item 1: a TableOwner restart between a successful read and its
    # coverage-recording step must not crash the caller — the read already
    # returned good data; only the cache-warming metadata failed to record.
    # A future read simply misses and re-records, same as any other cold
    # start. Every other ETS accessor in this module already tolerates this
    # (entries/2, partitions/1, drop/3) — insert/3 was the one exception.
    ArgumentError -> :ok
  end

  @doc "Drops a single entry by id. Missing entries are a no-op."
  @spec drop(module(), term(), term()) :: :ok
  def drop(resource, tenant, entry_id) do
    table = TableOwner.table_name(resource)
    true = :ets.delete(table, {tenant, entry_id})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Clears the resource's entire ledger (all tenants)."
  @spec reset(module()) :: :ok
  def reset(resource) do
    table = TableOwner.table_name(resource)
    true = :ets.delete_all_objects(table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @typedoc """
  An invalidation epoch snapshot: `{counter, incarnation}`. Within one
  incarnation any bump strictly moves the counter; across a `TableOwner`
  restart or `reset/1` the incarnation is a fresh, never-repeating raw
  `System.unique_integer/1` draw, so a stale pre-restart pair can never
  compare equal to a post-restart one regardless of counter arithmetic (see
  `epoch/2`'s moduledoc for why a single seeded counter is not sufficient).
  """
  @type epoch :: {counter :: non_neg_integer(), incarnation :: integer()}

  # A 3-tuple key is structurally incapable of matching `entries/2`'s
  # `{{tenant, :_}, :"$1"}` select pattern (a 2-tuple key) or colliding with a
  # real entry key, for any tenant value including a tenant literally named
  # `:__mdl_meta__` (review-1 W-P6 / review-2 F11).
  defp epoch_key(tenant), do: {:__mdl_meta__, :epoch, tenant}

  @doc """
  Snapshots the current invalidation epoch for a resource+tenant, seeding it
  on first access.

  Must be taken **at the top of the read**, before any layer is consulted —
  a bump landing after this snapshot but before the source fetch completes
  is legitimately absorbed (the fetch sees the write); any bump after that
  is what `epoch_moved?/3` catches later. Returns the epoch pair, or
  `:unavailable` when the ledger itself is unavailable (`ensure_table`
  failed) or was reset/restarted between the seed attempt and the read-back
  — both degrade callers to skip caching, never crash. `:unavailable` is
  itself a valid `epoch0` to pass through the read path: `epoch_moved?/3`
  always treats it as moved.

  The seed-or-read is a **non-atomic two-step sequence, deliberately**: no
  single ETS op both inserts-if-absent and returns the resulting value. It
  is sound because the source fetch that follows this snapshot runs AFTER
  it — a bump landing between the two steps belongs to a write the
  about-to-run fetch will see, so the snapshot legitimately absorbs it.
  """
  @spec epoch(module(), term()) :: epoch() | :unavailable
  def epoch(resource, tenant) do
    case ensure_table(resource) do
      :ok ->
        table = TableOwner.table_name(resource)
        key = epoch_key(tenant)
        :ets.insert_new(table, {key, 0, System.unique_integer([:positive])})

        case :ets.lookup(table, key) do
          [{^key, counter, incarnation}] -> {counter, incarnation}
          [] -> :unavailable
        end

      {:error, :unavailable} ->
        :unavailable
    end
  rescue
    ArgumentError -> :unavailable
  end

  @doc """
  Whether the invalidation epoch has moved since `epoch0` was snapshotted —
  a plain, non-seeding lookup (a seeding check could never observe absence,
  making the "table gone" case dead code). Both absence and a pair mismatch
  count as moved: either means a write raced this read, or the table itself
  was reset/restarted underneath it — both must abort caching. An
  `epoch0` of `:unavailable` (the snapshot itself failed) is always moved.

  Any lookup failure (a dying/mid-restart table) is treated as moved too —
  conservative, never a crash on the caller's read path.
  """
  @spec epoch_moved?(module(), term(), epoch() | :unavailable) :: boolean()
  def epoch_moved?(_resource, _tenant, :unavailable), do: true

  def epoch_moved?(resource, tenant, epoch0) do
    table = TableOwner.table_name(resource)
    key = epoch_key(tenant)

    case :ets.lookup(table, key) do
      [{^key, counter, incarnation}] -> {counter, incarnation} != epoch0
      [] -> true
    end
  rescue
    ArgumentError -> true
  end

  @doc """
  Bumps the invalidation epoch for a resource+tenant — called by
  `AshMultiDatalayer.Coverage.Invalidation` before dropping any entries, for
  every write **including zero-drop ones** (skipping the bump when nothing
  matched reopens the exact race this mechanism exists to close).

  Uses the identical default tuple shape as `epoch/2`'s seed, so a
  never-read-then-written partition seeds a value no stale snapshot could
  equal. Bump failure is **non-fatal**: `on_write`/`drop_all` run after the
  authoritative write has already committed (or inside an external
  notification handler), so a raise from a dying/mid-restart table must
  never crash either — it is rescued and treated as "the epoch moved (or
  the table is gone), best effort". This is conservative, not stale: a
  table restart already erased the coverage the bump was protecting.
  """
  @spec bump_epoch(module(), term()) :: :ok
  def bump_epoch(resource, tenant) do
    table = TableOwner.table_name(resource)
    key = epoch_key(tenant)
    :ets.update_counter(table, key, {2, 1}, {key, 0, System.unique_integer([:positive])})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Whether a query's row coverage may be recorded (and its rows backfilled).

  Truncated result sets can't prove complete coverage of a filter: queries
  with `limit`, a non-zero `offset`, `distinct`, `distinct_sort`, or a
  `lock` are never recorded — recording one would later serve incomplete
  results as a cache hit. Sort does not affect set membership and is fine.
  Calculations/aggregates don't affect recordability: the *rows* fetched
  alongside them are complete for the filter (the computed values themselves
  are never recorded — see the computed-value merge-reads ADR).
  """
  @spec recordable?(Query.t() | struct()) :: boolean()
  def recordable?(%Query{} = query) do
    is_nil(query.limit) and
      query.offset in [nil, 0] and
      query.distinct in [nil, []] and
      query.distinct_sort in [nil, []] and
      is_nil(query.lock)
  end

  @doc """
  The shared gate for anything that would replay the query against a cache
  layer for bookkeeping purposes (the remainder planner's split, and the
  read path's reconcile-on-record step): `recordable?(query) and not
  normalised.opaque?`, normalising the filter once so callers that also need
  the normalised probe (reconcile, `record`) don't re-normalise.

  An opaque probe (a calc/aggregate ref, or any shape outside the supported
  predicate set) must never split or be reconciled against the cache layer —
  it cannot prove what a cache-side replay would return, so both the
  remainder planner and reconcile treat it exactly like a full-hit miss:
  fall through whole to the source (review-2 F3).
  """
  @spec recordable_gate(Query.t() | struct(), module()) :: {boolean(), Normaliser.Normalised.t()}
  def recordable_gate(%Query{} = query, resource) do
    normalised = Normaliser.normalise(query.filter, resource)
    {recordable?(query) and not normalised.opaque?, normalised}
  end

  @doc """
  Looks for a recorded filter that provably covers the query.

  A hit requires an entry whose normalised filter is implied by the probe's
  (probe ⊆ cached) **and** whose `loaded_fields` are a superset of the
  fields the query needs. Returns `{:ok, entry}` (bumping its LRU
  timestamp) or `{:miss, reason}` with reason one of `:solver_unsupported`,
  `:no_coverage_entry`, `:fields_insufficient`, or `:ledger_unavailable`.
  """
  @spec covers?(module(), term(), Query.t() | struct()) ::
          {:ok, Entry.t()} | {:miss, atom()}
  def covers?(resource, tenant, %Query{} = query) do
    case ensure_table(resource) do
      :ok ->
        probe = Normaliser.normalise(query.filter, resource)

        if probe.opaque? do
          {:miss, :solver_unsupported}
        else
          find_covering_entry(resource, tenant, probe, needed_fields(query, resource))
        end

      {:error, :unavailable} ->
        {:miss, :ledger_unavailable}
    end
  end

  @doc """
  The current coverage region for a resource+tenant, as
  `{coverage_filter, complement_filter}` (see
  `AshMultiDatalayer.Coverage.Complement`), or `:none` when nothing is cached.

  `C` is the union of every current ledger entry's normalised filter **whose
  `loaded_fields` are a superset of `needed`** — a per-entry field gate,
  exactly like a full hit (plan rule 4 of the partial-serving-remainder-reads
  plan). A legitimately-narrow entry must not contribute region to a wider
  query's split even after `needed_fields` itself is widened (C1): entries
  failing the gate contribute nothing to `C` and their rows are fetched from
  the source via `¬C` instead — correct, merely less cached.

  Remainder reads serve `Q ∧ C` from the cache and fetch only `Q ∧ ¬C` from
  the source.
  """
  @spec coverage_split(module(), term(), MapSet.t(atom())) ::
          {Complement.region(), Complement.region()} | :none
  def coverage_split(resource, tenant, needed) do
    disjuncts =
      resource
      |> entries(tenant)
      |> Enum.filter(&MapSet.subset?(needed, &1.loaded_fields))
      |> Enum.flat_map(& &1.normalised.disjuncts)
      |> Enum.uniq()

    case disjuncts do
      [] ->
        :none

      _ ->
        {Complement.coverage_filter(disjuncts, resource),
         Complement.complement_filter(disjuncts, resource)}
    end
  end

  defp find_covering_entry(resource, tenant, probe, needed_fields) do
    entries = entries(resource, tenant)

    implying = Enum.filter(entries, &Implication.implies?(probe, &1.normalised))

    case Enum.find(implying, &MapSet.subset?(needed_fields, &1.loaded_fields)) do
      %Entry{} = entry ->
        touch(resource, tenant, entry)
        {:ok, entry}

      nil when implying != [] ->
        {:miss, :fields_insufficient}

      nil ->
        {:miss, :no_coverage_entry}
    end
  end

  @doc """
  Records that the query's filter has been fully materialised into the
  earlier read layers, guarded by the invalidation epoch snapshotted at
  `epoch0` (see `AshMultiDatalayer.Coverage.Invalidation` and the read-path
  protocol in the fix plan). `normalised` is the pre-normalised probe from
  the shared gate (`recordable_gate/2`) — the caller has already checked
  `recordable?`/opaqueness; `record/5` does not re-check them.

  **Check-insert-verify** (not a pre-check alone): the epoch is checked
  before touching the ledger; on a fresh entry, it is inserted and then the
  epoch is re-read — if it moved, the just-inserted entry is dropped by id.
  Pre-checks alone leave one window open: a writer's bump-then-drop-scan
  landing between this function's own pre-check and its ETS insert would
  let a pre-write entry survive (the drop-scan ran before the entry
  existed). The post-insert verify closes it: if the bump happened before
  our verify, we drop our own entry; if the bump happens strictly after our
  verify, our insert necessarily preceded the writer's drop-scan (`on_write`
  enumerates entries AFTER bumping), so the writer's own scan removes it.
  The fingerprint-widening path (below) follows the identical discipline —
  a widened claim from a racing/aborted backfill is a field-level version of
  the same hazard, so a mid-widen epoch move drops the entry entirely
  (conservative: the write may or may not have actually touched this
  region, but distinguishing the two would need per-row tracking this
  mechanism doesn't have — a transient hit-rate cost, never staleness).

  On a fingerprint match against an existing entry (post epoch-check), the
  query's `needed_fields` are UNIONED into that entry's `loaded_fields`
  instead of being a no-op (review-2 F2): sound because the backfill that
  just ran wrote those fields into the physical rows, and it is what stops
  a narrow-then-wide same-filter workload from being a permanent miss loop.
  Two readers concurrently widening the same entry with disjoint field sets
  is a last-writer-wins union on the metadata only — the physical rows are
  unaffected (`force_change_attributes` never strips fields) — so absent an
  epoch move the only consequence is a transient unnecessary miss a later
  read re-widens, never staleness; not worth a CAS loop (pass-3 S1).

  Returns `:ok` when a (new or pre-existing) entry now covers the filter,
  `:skipped` when the ledger cap was full, or `:epoch_moved` when a
  concurrent write aborted the recording.
  """
  @spec record(
          module(),
          term(),
          Query.t() | struct(),
          epoch() | :unavailable,
          Normaliser.Normalised.t()
        ) ::
          :ok | :skipped | :epoch_moved
  def record(resource, tenant, %Query{} = query, epoch0, %Normaliser.Normalised{} = normalised) do
    case ensure_table(resource) do
      :ok -> do_record(resource, tenant, query, epoch0, normalised)
      {:error, :unavailable} -> :skipped
    end
  end

  defp do_record(resource, tenant, query, epoch0, normalised) do
    if epoch_moved?(resource, tenant, epoch0) do
      :epoch_moved
    else
      fingerprint = dedupe_key(normalised)
      needed = needed_fields(query, resource)

      # L12 item 2: fingerprint is a bare :erlang.phash2/1 hash — a collision
      # (~30% birthday estimate at a full 10k-entry partition) would
      # otherwise match this to an UNRELATED entry, widening its
      # loaded_fields (serving never-backfilled fields as nil). The Entry
      # already carries the full canonical `normalised` term the fingerprint
      # was hashed from (needed for subsumption, not added for this fix) —
      # compare it too, disambiguating any hash collision.
      case Enum.find(
             entries(resource, tenant),
             &(&1.fingerprint == fingerprint and &1.normalised == normalised)
           ) do
        %Entry{} = existing ->
          widen_loaded_fields(resource, tenant, existing, needed, epoch0)

        nil ->
          insert_new_entry(resource, tenant, query, normalised, fingerprint, needed, epoch0)
      end
    end
  end

  defp insert_new_entry(resource, tenant, query, normalised, fingerprint, needed, epoch0) do
    if enforce_cap(resource, tenant) == :full do
      :skipped
    else
      entry = %Entry{
        id: make_ref(),
        tenant: tenant,
        filter: query.filter,
        normalised: normalised,
        fingerprint: fingerprint,
        loaded_fields: needed,
        loaded_at: System.monotonic_time()
      }

      insert(resource, tenant, entry)
      verify_or_drop(resource, tenant, entry.id, epoch0)
    end
  end

  defp widen_loaded_fields(
         resource,
         tenant,
         %Entry{loaded_fields: loaded} = existing,
         needed,
         epoch0
       ) do
    if MapSet.subset?(needed, loaded) do
      :ok
    else
      table = TableOwner.table_name(resource)
      widened = MapSet.union(loaded, needed)

      :ets.update_element(
        table,
        {tenant, existing.id},
        {2, %Entry{existing | loaded_fields: widened}}
      )

      verify_or_drop(resource, tenant, existing.id, epoch0)
    end
  rescue
    ArgumentError -> :skipped
  end

  defp verify_or_drop(resource, tenant, entry_id, epoch0) do
    if epoch_moved?(resource, tenant, epoch0) do
      drop(resource, tenant, entry_id)
      :epoch_moved
    else
      :ok
    end
  end

  # Hard per-resource-per-tenant cap: at the cap, evict the least-recently
  # used entry (hits refresh `loaded_at`). If eviction is impossible, emit
  # `:full` and treat the new filter as not recorded.
  defp enforce_cap(resource, tenant) do
    cap = Info.ledger_max_entries(resource)

    if size(resource, tenant) >= cap do
      case resource |> entries(tenant) |> Enum.min_by(& &1.loaded_at, fn -> nil end) do
        nil ->
          Telemetry.ledger(:full, resource, tenant, %{ledger_size: size(resource, tenant)})
          :full

        oldest ->
          drop(resource, tenant, oldest.id)

          Telemetry.ledger(:evicted, resource, tenant, %{
            ledger_size: size(resource, tenant)
          })

          :ok
      end
    else
      :ok
    end
  end

  @doc """
  The fields a query touches: everything a cache layer must physically hold
  to both backfill and re-evaluate the query — not just its select.

  The union of:

    * `query.select` (or all attributes when `nil`), plus the primary key;
    * attribute refs from `query.filter`;
    * `query.sort` fields (a calc-sort's expression refs, for the atoms
      directly);
    * `query.distinct` fields and `query.distinct_sort`'s refs;
    * attribute refs from every `query.calculations` expression — this is
      what makes a merged-read's cache-side probe (which carries the
      locally-evaluated calcs) demand the fields those calcs read.

  Only refs with an empty `relationship_path` that resolve to a real
  resource attribute count — a calc/aggregate ref or a related-path ref is
  not a field of this resource's own rows (and filters containing one are
  opaque to the normaliser regardless).
  """
  @spec needed_fields(Query.t() | struct(), module()) :: MapSet.t(atom())
  def needed_fields(%Query{} = query, resource) do
    select_fields =
      query.select ||
        Enum.map(Ash.Resource.Info.attributes(resource), & &1.name)

    MapSet.new(select_fields)
    |> MapSet.union(MapSet.new(Ash.Resource.Info.primary_key(resource)))
    |> MapSet.union(expression_attribute_refs(query.filter, resource))
    |> MapSet.union(sort_fields(query.sort, resource))
    |> MapSet.union(sort_fields(query.distinct_sort, resource))
    |> MapSet.union(MapSet.new(query.distinct || []))
    |> MapSet.union(calculation_fields(query.calculations, resource))
  end

  # `query.sort`/`query.distinct_sort` entries are `{field, direction}` with
  # `field` either a plain attribute atom, or `%Ash.Query.Calculation{}` for
  # a calc-sort (only locally-evaluable calc sorts ever reach a cache layer —
  # `sort_references_uncomputable_calc?` already guards the rest). A
  # calc-sort's expression lives at `calc.opts[:expr]`, NOT as a second tuple
  # element (that slot is the sort direction) — reading the wrong one would
  # silently return no fields for a calc sort (the M5-class hole).
  defp sort_fields(nil, _resource), do: MapSet.new()

  defp sort_fields(sort, resource) do
    Enum.reduce(sort, MapSet.new(), fn
      {%Ash.Query.Calculation{opts: opts}, _direction}, acc when is_list(opts) ->
        MapSet.union(acc, expression_attribute_refs(opts[:expr], resource))

      {field, _direction}, acc when is_atom(field) ->
        MapSet.put(acc, field)

      field, acc when is_atom(field) ->
        MapSet.put(acc, field)

      _other, acc ->
        acc
    end)
  end

  # `query.calculations` entries are `{calculation, expression}` tuples —
  # here `expression` (the second element) is already the hydrated
  # expression tree, unlike a calc-sort's `opts[:expr]`.
  defp calculation_fields(calculations, resource) do
    Enum.reduce(calculations, MapSet.new(), fn {_calculation, expression}, acc ->
      MapSet.union(acc, expression_attribute_refs(expression, resource))
    end)
  end

  defp expression_attribute_refs(nil, _resource), do: MapSet.new()

  defp expression_attribute_refs(expression, resource) do
    expression
    |> Ash.Filter.list_refs()
    |> Enum.filter(&(&1.relationship_path == []))
    |> Enum.flat_map(fn ref ->
      case resource_attribute_name(ref.attribute, resource) do
        {:ok, name} -> [name]
        :error -> []
      end
    end)
    |> MapSet.new()
  end

  # Mirrors `Normaliser.ref_attribute/2`'s attribute-vs-calc/aggregate
  # distinction: a calc/aggregate struct also carries `:name`/`:type` keys,
  # so it must be excluded BEFORE the generic `%{name: name}` match — treating
  # one as a plain attribute would demand a field that doesn't exist on the
  # resource's rows.
  defp resource_attribute_name(%struct{}, _resource)
       when struct in [
              Ash.Query.Calculation,
              Ash.Resource.Calculation,
              Ash.Query.Aggregate,
              Ash.Resource.Aggregate
            ],
       do: :error

  defp resource_attribute_name(%{name: name}, _resource), do: {:ok, name}

  defp resource_attribute_name(name, resource) when is_atom(name) do
    case Ash.Resource.Info.attribute(resource, name) do
      %{name: name} -> {:ok, name}
      _ -> :error
    end
  end

  defp resource_attribute_name(_other, _resource), do: :error

  # Dedupe key: the canonicalised normalised form INCLUDING literal values —
  # unlike the telemetry fingerprint, which type-tags values away. Two
  # syntactically different but equivalently normalised filters share a key.
  defp dedupe_key(%{disjuncts: disjuncts}) do
    disjuncts
    |> Enum.map(fn disjunct ->
      disjunct
      |> Enum.map(fn {attr, interval} ->
        {attr, interval.kind, interval.lower, interval.upper, Enum.sort(interval.values)}
      end)
      |> Enum.sort()
    end)
    |> Enum.sort()
    |> :erlang.phash2()
  end

  @doc false
  # LRU-touch on a coverage hit. `:ets.update_element/3` returns `false`
  # instead of recreating the key when it's gone — an unconditional `insert`
  # would resurrect an entry `Invalidation.on_write/4` just dropped for a
  # concurrent write whose cache-propagation then failed (M1): `covers?`
  # snapshots entries, a writer drops one and its propagation fails (exactly
  # the case invalidate-before-propagate is designed for), then the reader's
  # touch would recreate it, serving pre-write rows indefinitely and
  # defeating the invalidation-before-propagation ordering from the inside.
  # `@doc false` and public only so `AshMultiDatalayer.TestSupport.touch_entry!/3`
  # has a deterministic seam to test this race's fix without a scheduler.
  @spec touch(module(), term(), Entry.t()) :: boolean()
  def touch(resource, tenant, entry) do
    table = TableOwner.table_name(resource)

    :ets.update_element(
      table,
      {tenant, entry.id},
      {2, %Entry{entry | loaded_at: System.monotonic_time()}}
    )
  rescue
    ArgumentError -> false
  end

  @doc "Current ledger size for a resource+tenant (for telemetry)."
  @spec size(module(), term()) :: non_neg_integer()
  def size(resource, tenant) do
    table = TableOwner.table_name(resource)
    key = tenant
    :ets.select_count(table, [{{{key, :_}, :_}, [], [true]}])
  rescue
    ArgumentError -> 0
  end

  defp start_owner(resource) do
    case DynamicSupervisor.start_child(
           AshMultiDatalayer.TableSupervisor,
           {TableOwner, resource}
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> unavailable(resource, reason)
    end
  catch
    :exit, {:noproc, _} -> unavailable(resource, :supervisor_not_running)
  end

  defp unavailable(resource, reason) do
    warn_once(resource, reason)
    {:error, :unavailable}
  end

  defp warn_once(resource, reason) do
    key = {:ash_multi_datalayer, :supervisor_warning_logged}

    unless :persistent_term.get(key, false) do
      :persistent_term.put(key, true)

      Logger.warning("""
      ash_multi_datalayer could not start the coverage-ledger owner for \
      #{inspect(resource)} (#{inspect(reason)}). Reads will fall through to \
      the source of truth without caching. Add AshMultiDatalayer.Supervisor \
      to your application's supervision tree.
      """)
    end
  end
end
