# Plan: fix the critical findings (C1, C2, C3, C4, M1)

**Date**: 2026-07-05 (amended same day after twelve review passes — see
[Review disposition](#review-disposition) at the end)
**Input**: [implementation review](../reviews/20260704-implementation-review.md)
(findings confirmed with executing repros at `b9ddc8c`), repro artifact
`docs/reviews/repro_fields_test.exs.artifact`, the
[C4 addendum](../reviews/20260705-c4-destroy-eviction-addendum.md) (external
invalidation leaves physical rows; coverage re-recording resurrects them —
found downstream in `ash_remote_cache`, reproduced there deterministically),
and the twelve plan review passes
(`docs/reviews/20260705-critical-bugs-fix-plan-review*.md` — pass 4
adjudicates pass 3, pass 5 verifies the `forget!` probe rule against the Ash
evaluator, pass 6 corrects the epoch mechanism adopted from pass 4, pass 8
corrects a justification inherited from pass 5, passes 11–12 confirm
convergence with editorial findings only).
**Scope**: the four criticals plus M1 — M1 is one line and belongs to the same
invariant class as C3 (concurrent invalidation must never be undone). M2–M7 and
R1–R3 are *not* in this plan.
**Sequencing**: this plan lands **before** the orchestrator extraction
([ADR](../design/20260705-orchestrator-behaviour-adr.md)) — the fixes live in
exactly the code the extraction moves.

## The invariants being restored

1. **Field sufficiency** (C1, C2): a cache layer may only evaluate or serve a
   query over rows that physically contain every field the query *touches* —
   selected fields, filter-referenced fields, sort/distinct-referenced fields,
   and fields referenced by locally-evaluated calculation expressions. This
   must hold on the **record side** (what gets backfilled and stamped into
   `loaded_fields`) and the **probe side** (what `covers?` and the remainder
   planner demand of an entry).
2. **Invalidation is final** (C3, M1): once a write invalidates coverage, no
   in-flight read may re-establish coverage (or cache rows *under existing
   coverage*) computed from pre-write state. Per review-2 F1, "in-flight"
   includes a read whose coverage insert lands *after* the writer's drop-scan
   — the protocol below closes that window with a post-insert verify, not
   just pre-checks.
3. **Covered region ⇒ the physical rows under it are fresh** (C4): recording
   coverage for a filter must never launder stale physical rows into served
   state — neither ghosts of externally-destroyed rows nor pre-update values
   of rows that moved out of the region.

A cross-cutting correction from both reviews: everything below is specified
for **both** backfilling read paths. `source_read` has one fetch and one
authoritative row set; `remainder_read` has **two fetches (cache half first,
then source half)** and a blended result — every snapshot point, backfill
input, and reconcile set is stated explicitly for it.

## Phase 0 — regression harness first

1. Copy `docs/reviews/repro_fields_test.exs.artifact` into
   `test/integration/field_coverage_test.exs` (it is `@moduletag :integration`
   compatible). Run it; confirm the three tests fail for the review's reasons.
   These stay failing until Phases 1–2 land — they are the acceptance gate.
2. Build `test/support/blocking_layer.ex`: a wrapper data layer (modeled on
   `test/support/counting_layer.ex`) that delegates every callback to a target
   layer but can park on a message from the test process. **The park must
   happen *after* delegating**: `run_query` captures the target's (pre-write)
   result, *then* blocks, *then* returns the captured rows (review-2 F12 —
   blocking before delegation would fetch post-write values on resume and the
   race would not reproduce).
3. C3 race tests (`test/integration/read_write_race_test.exs`), both shapes:
   - **Full-miss**: reader misses and blocks after the source fetch → writer
     commits an update through `WriteDispatch` → reader resumes. Assertion
     **ordering matters** (pass-7 F2): first, immediately after the raced
     reader resumes and *before any further read*, assert **no ledger entry
     exists for Q** (the entry-resurrection check — a later healing read
     would legitimately re-record Q and turn this assertion into a false
     failure); only then perform the follow-up identical read and assert it
     returns the **written** value.
   - **Remainder** (review-1 C-P1 / review-2 F5): reader runs the *cache-side*
     region read and blocks → writer commits → reader resumes the source half.
     Assert the merged result, the backfill, and any recorded coverage reflect
     the write, never the stale cache-half rows.
   Confirm both fail deterministically before Phase 3.
4. C4 ghost tests (`test/integration/external_invalidation_test.exs`), porting
   the addendum's downstream repro shapes — each exercised through **both** the
   full-miss and the remainder read path (review-1 C-P2 pins this): (a)
   external destroy → `Invalidation.on_write(resource, tenant, row, nil)` →
   re-covering read of a matching filter → the next hit must **not** serve the
   destroyed row; (b) the unrelated-remainder shape (an unrelated entry's
   region contains the ghost); (c) the update variant — external update moves
   the row out of a region, a later covered read of that region must not serve
   pre-update values.
5. Repro-attempt test for a **calculation ref embedded in a filter** reaching
   the remainder path (review-2 F3): pin whether such filters arrive at the
   data layer unexpanded, and that the opaque-probe gate (Phase 2) keeps them
   off the cache half. The full-hit path's safety here is proven (opaque ⇒
   never a hit); the remainder path's was presumed.

## Phase 1 — C1: widen `needed_fields/2` to everything the query touches

**File**: `lib/ash_multi_datalayer/coverage.ex:244-251`.

`needed_fields(query, resource)` becomes the union of:

- the current set: `query.select` (or all attribute names when `nil`) ∪ PK;
- attribute refs of `query.filter` — via `Ash.Filter.list_refs/1`, keeping
  only refs with `relationship_path == []` whose target is a resource
  attribute (related-path refs are not fields of this resource's rows; filters
  containing them are opaque to the normaliser, and Phase 2 now keeps opaque
  probes off the remainder path too);
- `query.sort` fields: atoms directly; `{%Ash.Query.Calculation{}, _}` sorts
  contribute their expression's refs (only locally-evaluable calc sorts reach
  a cache layer — `sort_references_uncomputable_calc?` already guards the
  rest);
- `query.distinct` / `query.distinct_sort` refs (recording is already blocked
  for these by `recordable?`, but the **probe** side must demand them);
- expression refs of every calculation in `query.calculations` — this is what
  makes `merged_read`'s probe with `cache_query` (which carries the
  locally-evaluated calcs, `data_layer.ex:842-845`) demand the fields those
  calcs read.

Implementation notes:

- Add a private `expression_attribute_refs(expr, resource)` helper wrapping
  `Ash.Filter.list_refs/1` + the path/attribute filtering; reuse it for
  filter, calc expressions, and calc sorts. **The expression lives in a
  different place per case** (review-2 S-P1): `query.calculations` carries
  `{calc, expression}` tuples (expression is the second element), while a
  calc-*sort* entry is `{calc, direction}` and its expression is
  `calc.opts[:expr]` (`data_layer.ex:732-738`). The helper's callers must
  read the right one — silently getting `[]` for calc-sorts would reopen the
  M5-class hole.
- Before wiring into the hot path, verify in `iex` against the pinned Ash
  version that `Ash.Filter.list_refs/1` tolerates `nil`/degenerate filters
  and that the `relationship_path == []` filtering behaves as assumed
  (review-1 S-P2). The function must stay total — it runs on every read.

**Fingerprint-match widening** (review-2 F2 — P1): `Coverage.record`'s dedupe
returns `:ok` without touching the existing entry when the fingerprint matches
(`coverage.ex:192-194`). Left alone, a narrow-then-wide same-filter workload
becomes a *permanent* miss loop: the wide read misses on `:fields_insufficient`,
does a full source read, backfills the wider fields into the physical rows —
and then the record is deduped away, so the entry still claims the narrow set
and the next wide read misses again, forever. Fix: on fingerprint match,
**union the query's `needed_fields` into the existing entry's
`loaded_fields`** — sound exactly because the backfill that just ran wrote
those fields into the physical rows. The widening must go through
`:ets.update_element` (never a blind insert — the M1 lesson) and, once Phase 3
lands, sits inside the same epoch discipline as the insert path (a widened
claim from an aborted backfill would be a field-level C3). One known
imprecision, accepted (pass-3 S1): two readers concurrently widening the same
entry with disjoint field sets are a last-writer-wins union on the *metadata*
— the physical rows are unaffected (`force_change_attributes` never strips
fields), so the consequence is a transient unnecessary miss that a later read
re-widens, never staleness. Not worth a CAS loop. This also defuses
the main case of review-1 W-P3's fragmentation concern (narrow entries
accumulating per select shape): same-filter entries widen in place instead of
piling up. Cross-*filter* fragmentation (distinct filters, each with its own
entry) remains possible and is accepted for now — the LRU cap bounds it; a
subsumption-merge of entries is out of scope.

**The other half — the source rows must physically contain those fields.**
`Delegate` replays `query.select` verbatim, so a narrow-select source read
returns rows *without* the filter fields; listing them in the backfill `fields:`
opt would just copy `nil`s (worse: `%Ash.NotLoaded{}`s, review N8). Fix in
`lib/ash_multi_datalayer/data_layer.ex`: on read paths that may backfill
(`source_read`, and the **source side** of `remainder_read`), when
`Coverage.recordable?(query)` and there are earlier layers and
`query.select != nil`, run the source query with
`select: Enum.to_list(needed_fields(query, resource))` (a superset of the
caller's select). Caller-visible results are unchanged — Ash core narrows the
final result to the action's select (same reason ETS returning full rows is
fine, `data_layer.ex:302-305` comment) — but add an explicit test asserting
the caller-visible shape anyway. `maybe_backfill`'s `fields:` opt keeps using
`needed_fields` (unchanged shape, now-wider set), and `Coverage.record` stamps
the same set into `loaded_fields` — record side and probe side compute from
the **same query**, so they agree by construction.

(No change needed in `Debug` — it calls `needed_fields` itself, so
`mix ash_multi_datalayer.inspect` inherits the widening; noted per review-2
F13.)

**Acceptance**: repro tests 1 (identical repeat read: 2 rows, twice) and the
merged-read calc test (`adult? == [false, true]` from cache) pass; the second
read is asserted to be a coverage **hit** (telemetry), not a fixed-by-missing
fallthrough.

## Phase 2 — C2: per-entry field gate in the remainder planner

**Files**: `lib/ash_multi_datalayer/coverage.ex:140-155`,
`lib/ash_multi_datalayer/data_layer.ex:769-784`.

This is plan rule 4 of
[partial-serving-remainder-reads-plan.md](./partial-serving-remainder-reads-plan.md),
dropped in implementation — and it is **not** subsumed by Phase 1: a
legitimately-narrow entry (recorded by a genuinely narrow-select query) still
must not contribute region to a wider query's split.

- `Coverage.coverage_split/2` → `coverage_split(resource, tenant, needed)`:
  filter `entries(resource, tenant)` to those with
  `MapSet.subset?(needed, entry.loaded_fields)` **before** unioning disjuncts.
  Entries failing the gate contribute nothing to `C` (their rows are fetched
  from the source via `¬C` instead — correct, merely less cached; the Phase 1
  fingerprint widening keeps this from becoming a steady state for repeated
  filters).
- `remainder_plan/2` passes `Coverage.needed_fields(query, resource)` (the
  Phase-1-widened set).
- **Opaque probes never split** (review-2 F3): `remainder_plan` currently runs
  for *any* miss reason, including `:solver_unsupported` — so a filter the
  normaliser can't see through (calc ref, unsupported predicate) still gets
  its "covered half" evaluated by the cache layer, with its demands invisible
  to every field set this plan builds. Gate `remainder_applicable?` on
  `not probe.opaque?` (thread the probe from `covers?`'s miss, or
  re-normalise). Cost: opaque filters fall through whole — which they already
  do on the full-hit path, and they can never record coverage anyway; matches
  the project's conservative-on-unknown rule.

**Acceptance**: repro tests for C2 pass — (a) the wider-select read returns
`age: 30` for the cached row (served from source because the narrow entry no
longer contributes region); (b) the vanishing-row scenario returns both rows,
and the follow-up assertion that coverage was *not* poisoned (the next full
read still returns both rows and is not served from a wrong entry). After the
Phase 1 fingerprint widening, additionally assert the **third** wide read in
(a) is a coverage *hit* (telemetry kind) — the anti-miss-loop check.

## Phase 3 — C3: invalidation epoch guarding backfill and record

**Files**: `lib/ash_multi_datalayer/coverage.ex`,
`lib/ash_multi_datalayer/coverage/invalidation.ex`,
`lib/ash_multi_datalayer/data_layer.ex`.

### Mechanism

- Per resource+tenant **epoch counter** in the existing coverage ETS table
  under the three-element key `{:__mdl_meta__, :epoch, tenant_key}` — a
  3-tuple key is *structurally* incapable of matching `entries/2`'s
  `{{tenant, :_}, :"$1"}` pattern or colliding with a 2-tuple entry key, for
  any tenant value including pathological atoms (review-1 W-P6 / review-2
  F11; the plan's earlier `{:__epoch__, tenant}` shape collided with a tenant
  literally named `:__epoch__`).
- **The epoch is a pair `{counter, incarnation}`, seeded lazily and
  atomically at first access** (review-2 F6, mechanism corrected twice: the
  original "seed in `TableOwner.init` / re-seed in `reset/1`" is
  unimplementable — epochs are per-tenant and the tenant set is unbounded
  and lazy, and "absent ⇒ abort" alone would abort every backfill on a
  read-only cold start, contradicting Phase 1's own second-read-is-a-hit
  acceptance gate (pass-4 N1 / pass-3 W2); and a *single* seeded counter is
  not collision-free (pass-6 F1) — bumped values are `seed + k`, and
  `System.unique_integer([:positive])` draws from dense scheduler-striped
  small integers, so a fresh post-restart seed can numerically equal a
  pre-restart bumped value, letting the exact crash-window race the seeding
  exists to close slip through on arithmetic coincidence).
  The object is `{key, counter, incarnation}`; readers snapshot and compare
  the **pair**. Within one incarnation any bump strictly moves the counter
  (the C3 guarantee); across a TableOwner restart or `Coverage.reset/1` the
  incarnation is a fresh *raw* `unique_integer` output, which never repeats
  within the VM's lifetime — so no stale pair can compare equal regardless
  of counter arithmetic. (A full node restart wipes the readers too.)
- **Snapshot** (`Coverage.epoch/2`): begins with `ensure_table(resource)` —
  pass-6 F2: the calc-sort-source-only and non-mergeable read branches reach
  `maybe_backfill` *without ever passing through `covers?`*, so without this
  the first such read finds no table, aborts, and that query shape never
  caches from a cold start (the cold-start hole through a side door). Abort
  caching only when `ensure_table` itself returns `{:error, :unavailable}`
  (the existing degraded mode). Then seed-or-read: `:ets.insert_new` with
  `{key, 0, System.unique_integer([:positive])}` followed by a lookup. This
  is a **two-step, non-atomic sequence — deliberately** (pass-8 F2 /
  pass-10 S1: no single ETS op both inserts-if-absent and returns the pair).
  It is sound because the source fetch runs *after* the snapshot: a bump
  landing between the two steps belongs to a committed write the fetch
  already sees, so the snapshot legitimately absorbs it; any *further* write
  still mismatches at check time. The one non-benign corner: absence at the
  lookup *after* the seed attempt (a `reset/1` or table death mid-snapshot)
  ⇒ abort caching, consistent with the rescue posture. Cost note
  (pass-5 S1): seed-or-read takes the ETS write lock on the per-tenant epoch
  key, making every miss-path read perform one small ETS write — accepted
  for the mechanism's simplicity (the hit path never touches the epoch); if
  profiling ever shows contention, the read-mostly shape (`lookup` first,
  `insert_new` only on the rare absent case, re-`lookup`) is the drop-in.
- **Check-time reads are a plain non-seeding `:ets.lookup`** (pass-6 F3 — a
  seeding check could never observe absence, making the abort clause dead
  text): absence *or* pair mismatch at check time ⇒ abort caching / drop the
  entry.
- `Coverage.bump_epoch/2` — `:ets.update_counter/4` incrementing the counter
  element, with the **identical default tuple shape** as the snapshot's seed
  (pass-5 S2 — a diverging default, e.g. bare `0`, would let a
  never-read-then-written partition seed a value a stale snapshot could
  equal). **Bump failure is non-fatal** (pass-7 F1): `on_write`/`drop_all`
  run after the authoritative write has committed (or inside an external
  notification handler) — a raise from a dying/mid-restart table must not
  crash either; rescue, treat the epoch as moved/unavailable, continue with
  best-effort ledger drops and physical eviction, never fail the committed
  write. Conservative, not stale: a table restart already erased the
  coverage the bump was protecting. **This posture rests on a two-legged
  invariant** (pass-10 S2, refined by pass-12 F2 — state both legs in the
  code comment): the C3-reopening arrangement (bump fails, epoch unmoved,
  drops *succeed*, an in-flight reader re-records over them) is unreachable
  because *either* (a) bump and drops operate on the same ETS table and fail
  together, *or* (b) an interleaving where the drops outlive a failed bump
  necessarily crossed a table recreation — which refreshed the incarnation,
  so every stale reader's check mismatches, and the entries the drops remove
  on the fresh table were recorded from post-write fetches (a hit-rate cost
  only). A future refactor moving the epoch to a different store
  (`:persistent_term`, its own table) breaks *both* legs and must make the
  bump-failure path abort the write's invalidation explicitly.
- All epoch reads/verifies are likewise rescue-safe (pass-4 N7, same class
  as review N3): an `ArgumentError` from a dying table is treated as
  "moved" — abort caching / drop the entry — never a crash on the caller's
  read path.
- `Invalidation.on_write/4` and `Invalidation.drop_all/2` bump the epoch of
  the partition they touch (singular — the tenant/`:__global__` cross-sweep
  is M6's problem and explicitly out of scope here; review-2 F10),
  unconditionally, **before** dropping entries. **Unconditionally includes
  zero-drop invalidations**: review-1 W-P2(c) suggested skipping the bump
  when `should_drop?` matched no entries, and that is *unsound* — the
  original C3 repro is precisely a write against a ledger with nothing to
  drop racing an in-flight miss. Rejected; recorded in the decisions below.

### Read-path protocol

1. Snapshot `epoch0` **at the top of the read, before any layer is
   consulted** — for `source_read` that is before the source fetch; for
   `remainder_read` it is before `coverage_split` and the **cache-side**
   `run_region` (review-1 C-P1 / review-2 F5: the cache half runs *first* and
   its rows used to reach the backfill, so a snapshot taken only before the
   source fetch is blind to a writer landing between the two halves).
2. In `maybe_backfill`: re-read the epoch **before upserting** — if moved (or
   absent), skip backfill *and* record entirely (the fetched rows are still
   returned to the caller; the read result itself is not stale, only unsafe
   to cache).
3. **Check-insert-verify** (review-2 F1 — P1): pass `epoch0` into
   `Coverage.record` (the discipline must bracket the *insert*, which sits
   behind record's dedupe-scan and cap-eviction, not the whole of
   `maybe_backfill`). Record checks the epoch before inserting, inserts, then
   re-reads the epoch: if it moved, **drop the just-inserted entry by id**.
   Pre-checks alone leave one window — the writer's bump→drop-scan landing
   between the reader's final check and its ETS insert — in which a pre-write
   entry is inserted after the drop-scan and survives; if the writer's
   propagation then *fails* (exactly the case invalidate-before-propagate is
   designed for), that entry serves stale rows indefinitely. The verify
   closes it: bump-before-verify ⇒ the reader deletes its own entry;
   bump-after-verify ⇒ the insert preceded the writer's drop-scan
   (`on_write` enumerates entries *after* bumping), so the writer's own scan
   drops it. The Phase 1 fingerprint-widening path follows the same
   discipline (check, `update_element`, verify, drop-on-move).
   **Signature note** (pass-3 S2, updated per pass-8 F3): `record` gains
   **two** additions — `epoch0` and the pre-normalised probe from the shared
   gate (the pass-6 F4 adoption; pass the pair as an opts keyword or
   `record/5`, implementer's choice, but Phases 3.3 and 4.2 must describe
   the same function). One lib caller (`data_layer.ex:904`) plus the
   existing `Coverage` unit tests (dedupe/cap/LRU) need updating; the
   reconcile PK set deliberately stays *out* of `record`'s signature (see
   Phase 4.2's placement decision).
4. **Backfill inputs are source-half rows only** (review-2 F4): on the
   remainder path, `maybe_backfill` receives the **source region's rows**,
   not `merged`. Cache-origin rows are already physically present (recording
   Q needs nothing re-upserted for them), and re-upserting them has two
   failure modes: behind a select-honouring cache layer the narrow cache-half
   structs would clobber good values with `%Ash.NotLoaded{}` sentinels
   (review N8's mechanism on a new path), and any stale/ghost cache-half row
   would be laundered into "freshly backfilled" state. The *caller* still
   gets `merged`; only the backfill/record/reconcile pipeline narrows to the
   source half.
5. **`maybe_backfill`'s consolidated contract** (pass-11 S1 / pass-12 F3 —
   it is the aggregation point for every piece of threaded state, and its
   new inputs were previously scattered across four bullets):
   `maybe_backfill(query, resource, read_layers, source_rows, epoch0, opts)`
   with `opts[:complement]` (the ¬C filter, `nil` on the full-miss path) and
   `opts[:probe]` (the normalised probe from the shared gate, passed through
   into `record`). `source_rows` replaces today's `records` argument
   (`data_layer.ex:890`), which currently receives `merged`.

Emit `Telemetry.read(:backfill_aborted, ...)` with the reason on any skip or
verify-drop.

### Why this closes the class, and the residual window (document in code)

The check before upsert prevents landing stale rows *under another reader's
subsequent coverage*; check-insert-verify makes recording itself
race-free (above). The residual race — writer invalidates between check 2 and
the upsert — leaves a stale row in the cache **without any coverage entry
claiming it**: every pre-existing entry matching that row matched the write's
before-image and was dropped by the synchronous invalidation (and Phase 5
prevents its resurrection via `touch`). Uncovered rows are unservable, and a
later miss's backfill overwrites them; a later reader recording fresh coverage
first overwrites the row with its own backfill before recording, and any field
it didn't backfill is outside its `loaded_fields` gate (Phases 1–2). So the
restored invariant is precisely: **no coverage entry ever claims pre-write
state** — not "cache rows are never stale", which unserved rows don't need.

### Cost, stated plainly (review-1 W-P2)

The abort window is the full source round trip — network-wide for the
flagship remote composition — and *every* write in the partition moves the
epoch. Under sustained write concurrency a meaningful fraction of read-miss
backfills will abort recording, and coverage warms slowly or not at all. That
is the correct trade (NFR2 puts freshness above hit rate), but it is not
free: Phase 6's stress test must **measure cache hit rate under write load**,
not only quiescence correctness, so the cost is a number rather than a
surprise. If it proves painful in practice, the sound refinements are
narrower epochs or entry-level guards — *not* skipping zero-drop bumps.

**Acceptance**: both Phase-0 race tests pass (full-miss and remainder), the
no-entry-at-quiescence assertion included; kept deterministic via the blocking
layer, not sleeps.

## Phase 4 — C4: external invalidation must evict; recording must reconcile

**Files**: `lib/ash_multi_datalayer/coverage/invalidation.ex`,
`lib/ash_multi_datalayer/coverage.ex`, `lib/ash_multi_datalayer/data_layer.ex`,
`lib/ash_multi_datalayer/backfill.ex`.

Adopts the addendum's fix directions 1 + 2 together, and 3 as the public API
the downstream bridge already proved out. Built in the same commit series as
Phase 3 — same `maybe_backfill`/`Coverage.record` region, same theme.

1. **`Invalidation.on_write/4` upholds the physical invariant itself — for
   destroys *and* external updates** (addendum fix 1, extended per review-2
   F7). After bumping the epoch and dropping entries, `on_write` also removes
   the physical row from every earlier read layer via
   `Backfill.destroy_record/4` (already treats already-absent as success):
   - destroy (`row_after == nil`): evict by the before-image's PK;
   - update (`row_before` and `row_after` both present): evict by the
     **before-image's** PK (pass-4 N4 — for a PK-changing external update the
     before-PK row is always the stale one; the after-PK row heals via normal
     upsert/refetch). Eviction needs only the PK — safe with partial
     notification payloads,
     where upserting a possibly-partial after-image would hit N8 — and once
     the entries are dropped, the row's absence is a *miss*, never staleness.
     This closes the update variant **at the API**, immediately, instead of
     waiting for some later read to re-record the region; the reconcile pass
     below becomes defense-in-depth for both variants. Cost: one cache miss
     per externally-updated row — that is what correctness costs. For *local*
     writes through `WriteDispatch` the evict is redundant churn
     (propagation re-upserts the fresh returned record immediately after);
     accepted for the single code path. Like the reconcile cost, "churn" is a
     **ProvenCoverage-topology** statement (pass-3 S3): with a remote earlier
     layer it is two network round trips per local update — a future strategy
     must revisit; say so in the code comment.
   - creates (`row_before == nil`): nothing to evict.
   - **Kill-switch interaction** (pass-4 N6): the evict runs regardless of
     the kill switch — it is part of invalidation, and invalidation is
     already "never skippable once the authoritative layer has committed".
     Update `WriteDispatch`'s moduledoc, whose current "propagation is
     skipped" wording would otherwise contradict a cache write happening
     while disabled.
   **Failure contract** (review-1 W-P5 / review-2 F8): eviction failure is
   swallowed — warning + telemetry, mirroring `WriteDispatch.propagate/5`'s
   posture — and never fails the surrounding operation: `on_write` runs
   inline after the authoritative write has already committed (local path)
   or inside an external notification handler; neither may crash. The
   residue of a failed evict (ghost row, entries already dropped) is exactly
   what the reconcile pass cleans — one more reason fixes 1 and 2 land
   together. Plumbing note (review-1 W-P1): the layers come from
   `Info.read_layer_modules/1`, but the domain does **not** live in MDL's
   `Info` — use `Ash.Resource.Info.domain(resource)`.
2. **Reconcile on coverage recording** — the defense in depth: in the
   epoch-guarded window (after `Backfill.upsert_records`, before
   `Coverage.record`'s insert), delete cached rows matching the recorded
   filter whose PK is not in the **source-fetched set** — never the merged
   set (review-1 C-P2 / review-2 F4: deriving "fetched" from `merged` lets a
   ghost that arrived via the cache half count as fetched and be laundered
   into a full hit).
   - **Code placement** (pass-3 W1 — the "after upsert, before insert" time
     description was ambiguous, and the ambiguity was load-bearing):
     reconcile lives in **`maybe_backfill`**, *not* inside `Coverage.record`
     — physical row deletion (`Delegate` + `Backfill`) does not belong in the
     ledger module, and this keeps the PK set out of `record`'s signature.
     The gating W1 actually requires is made explicit instead: `Coverage`
     exposes the shared gate (`recordable? and not normalised.opaque?`,
     normalising once) as a public helper; `maybe_backfill` consults it and
     runs reconcile + `record` only when it passes. An opaque query therefore
     never has Q replayed against the cache layer for reconciliation (which
     could not evaluate it — the exact path the C2/F3 work protects), and
     `record`'s internal gates remain as backstop. To avoid normalising Q
     twice per backfill (pass-6 F4), the gate returns the normalised probe
     and `maybe_backfill` passes it into `record` alongside `epoch0`.
   - **Where ¬C comes from** (pass-5 W1 — load-bearing, not cosmetic:
     scanning full Q on the remainder path and deleting ∉ source-set would
     delete every covered row, since covered rows are legitimately absent
     from the ¬C-only fetch): `remainder_read` already holds the complement
     from `remainder_plan`; it is **threaded into `maybe_backfill` as an
     explicit option** (`complement: ¬C_filter`), `nil` on the full-miss
     path where full Q is scanned. `maybe_backfill` must not recompute
     `coverage_split` itself — **threading is required by the reconcile's
     semantics, not a discipline nicety** (pass-8 F1, correcting a false
     justification inherited from pass-5 W1: the entry set is *not* stable
     across the epoch-guarded window — concurrent `record` inserts, LRU cap
     evictions, fingerprint widenings, and other readers' verify-drops all
     mutate it without a bump). "∉ source-fetched set" is only meaningful
     over exactly the region the source actually fetched; a mid-window
     recompute can yield `¬C′ ⊃ ¬C` and the reconcile would then delete
     fresh, legitimate, merely no-longer-covered rows in a region the source
     never fetched — silent cache erosion. Scan region and fetch region must
     be the same object.
   - On the full-miss path: scan Q against the cache via
     `Delegate.run_on_layer`, delete rows ∉ source-fetched PKs. **The
     reconcile query is filter-only, fully specified** (pass-9 F1/S1): the
     original resource/domain/tenant/context and the filter region, with
     `select: primary_key`, `sort: []`, `calculations: []`,
     `aggregates: []`, `distinct: []`, `distinct_sort: nil`, `limit: nil`,
     `offset: 0`, `lock: nil`. Clearing `sort` is not redundant with
     `recordable?` (which doesn't exclude sort): the
     `:calc_sort_source_only` branch reaches `maybe_backfill` with a sort
     referencing a calc the cache layer *cannot evaluate* — replaying it in
     the reconcile scan would reintroduce exactly the cache evaluation
     `sort_references_uncomputable_calc?` exists to avoid.
   - **Scan-failure contract** (pass-11 note): a `{:error, _}` from the
     reconcile's cache scan skips the reconcile, proceeds to `record` (which
     has its own epoch guard), and logs + telemeters. Neither failing the
     read (it already succeeded) nor skipping the record (the backfill was
     fine) is correct; any ghost a skipped reconcile leaves is unservable
     (its covering entries were dropped by invalidation) until the next
     re-covering read reconciles again — the defense-in-depth framing
     degrades gracefully by construction.
   - On the remainder path: scan **Q ∧ ¬C only** and delete rows ∉ the
     source half's PKs. The covered half needs no reconcile *and must not be
     reconciled against the source set* (its rows are legitimately absent
     from `¬C`'s fetch). This restriction is sound because invalidation
     drops every entry whose filter the before-image matched: a stale
     physical row's values *are* a before-image, so no surviving gated entry's
     region can contain it — the cache half cannot serve it, and with fix 1
     evicting on external destroy/update, recorded regions stay physically
     clean at the source of the problem too.
   - The epoch guard is what makes reconcile safe against concurrent local
     writes: a fresh row propagated by a concurrent create after our source
     fetch looks like "a row the source didn't return" — but that write
     bumped the epoch, so the reconcile+record step is skipped when the bump
     lands before the pre-reconcile check. If the bump lands *mid-reconcile*
     (pass-4 N2), the reconcile can still delete the concurrently-propagated
     fresh row — the record insert is then skipped by check/verify, so the
     outcome is a later cache **miss** on that row: tolerated degradation,
     never staleness. The code comment must describe it as such, so nobody
     "fixes" the wrong thing on observing it.
   - **Scope, stated honestly** (pass-4's adjudication of pass-3 F1):
     reconcile covers the evict-failure residue and regions being
     *re-recorded*. It is **not** a safety net for invalidation sources that
     never call `on_write` at all — a ghost under a surviving entry's valid
     coverage is served by plain covered reads today regardless of anything
     recording does, and no local mechanism can distinguish untold staleness
     under valid coverage from freshness. For those sources, `forget!` and
     LRU/coincidental invalidation are the only healers. Phase 6 pins which
     class reconcile does close.
   - Cost note (review-1 W-P4): "one extra cache-layer pass, never a source
     read" is a property of **ProvenCoverage's topology** (earlier layer =
     node-local cache), not of the mechanism — a future strategy with a
     remote earlier layer pays a round trip here and must revisit this.
     State it in the code comment.
3. **Promote the row-purge API from the downstream stopgap**:
   `AshMultiDatalayer.forget!(resource, pk_or_record, opts)` — for consumers
   that discover staleness out-of-band (the lost-notification case).
   Implementation reuses fix 1 wholesale (review-1 S-P6): `forget!` is
   `Invalidation.on_write(resource, tenant, record, nil)` — epoch bump +
   entry drops + physical evict — in a public wrapper, keeping `on_write/4`
   the single upholder of the physical invariant rather than a parallel
   implementation. **PK-only calls must build the probe record with non-PK
   attributes as `%Ash.NotLoaded{}`, never `nil`** (pass-3 F3 via pass-4's
   adjudication): under Ash's nil semantics `age > 5` over `age: nil` is a
   definite *non-match*, so a nil-built probe lets entries covering the
   row's true state survive the drop while the physical row is evicted — a
   covered read then silently loses the row. `NotLoaded` degrades filter
   evaluation to `:unknown` → conservative drop. Unit test: a PK-only
   `forget!` drops an entry whose filter references a non-PK field. This replaces `ash_remote_cache`'s `CacheLayer.evict!` and
   its reimplementation of `Delegate`'s filter application; follow-up
   (outside this repo): delete the bridge's stopgap and move
   `forget!`/`not_found?` usage onto the MDL API.

**Acceptance**: Phase-0 C4 tests (a) and (b) pass with fix 1 alone; (c) now
also passes with fix 1 (evict-on-update), with the reconcile pass additionally
pinned by a test that disables/fails the evict (the failure-contract path) and
still converges via reconcile. The downstream regression tests — in the
**downstream repo**, `../ash_remote_cache/example/todo_client/test/todo_client/live_test.exs:52`
and `:90` (review-2 F9 corrected the path) — still pass against the bridge
before its stopgap is removed.

## Phase 5 — M1: `touch` must not resurrect dropped entries

**File**: `lib/ash_multi_datalayer/coverage.ex:269-271`.

Replace `touch`'s unconditional `insert` with
`:ets.update_element(table, {tenant_key(tenant), entry.id}, {2, updated_entry})`
— returns `false` when the key is gone instead of recreating it; ignore the
return. Test seam, made concrete (pass-7 F3 — the previous instruction was
not implementable: `TestSupport` only exposes `reset!/1`, and `touch` fires
inside `covers?` with no deterministic way to drop the entry between the
select and the touch): `Coverage.touch/3` becomes `@doc false` public —
production `covers?` keeps calling it directly — and
`AshMultiDatalayer.TestSupport.touch_entry!/3` wraps it as the sanctioned
test entry point. This revisits review-1 S-P3's objection deliberately: its
alternative had no deterministic seam, and a probabilistic concurrency test
for a one-line race fix is worse than one `@doc false` function fronted by
the existing test-support module. Test: record an entry, drop it as
`Invalidation` would, `touch_entry!` the stale struct, assert the partition
stays empty via `:ets.lookup`.

## Phase 6 — harden the suite around the fixed class

1. **Field-modelling property** (closes the review's "fields are not modelled
   at all" generator gap): extend `test/support/generators.ex` with a random
   select subset; new property over the ETS+source stack — for random
   filter/select/rows, a cold read and the identical warm repeat read return
   the same rows **and the same field values**, a warm wider-select read
   equals a cold one, and the **narrow→wide→narrow** same-filter sequence
   ends covered (pins the Phase 1 fingerprint widening; review-2 F2). Add a
   merged-read variant with a locally-evaluable calc whose inputs are outside
   the select (review-1 S-P4) — the second C1 shape, property-formed.
2. **Concurrency stress test** (`:integration`): N writer tasks + M reader
   tasks over Postgres+ETS for a fixed op count, the writer mix biased to
   include **propagation-failure injections** (the F1 window) via the
   blocking/failing wrapper layer; at quiescence every recorded coverage
   entry's filter re-run against the cache equals the source (reuses the
   divergence-sampler comparison machinery — this quiescence check is
   invariant 2+3 in executable form). Additionally **report the cache hit
   rate under write load** (review-1 W-P2): the epoch-abort cost must come
   out of this test as a number.
3. Missing-test #1 from the review while we are in `maybe_backfill`: a failing
   cache layer during fall-through ⇒ no ledger entry, next identical read
   misses with correct rows (the code is believed correct; pin it).
4. Fold the C4 shapes into the stress test's op mix (external `on_write`
   destroys *and updates* alongside `WriteDispatch` ops).
5. **Reconcile-scope pin test** (pass-4's adjudication of pass-3 F1):
   two cases side by side — (a) evict-failure residue: `on_write` runs but
   the evict is failed via the wrapper layer; a later recording over the
   ghost's region converges via reconcile; (b) forgotten invalidation:
   `on_write` is never called; the ghost stays served under its surviving
   entry until `forget!` — asserting the *documented* limits, so the scope
   in Phase 4.2 is executable, not prose.

## Phase 7 — verification and bookkeeping

- Full suite: `mix test` and `INTEGRATION=1 mix test` (Postgres), plus the
  property suites; `mix format --check-formatted`; `mix credo --strict`;
  dialyzer. This plan touches `invalidation.ex` and `backfill.ex`, both
  carriers of R2's `Ash.Resource.record()` spec regression — **fix the specs
  in those two files** (`Ash.Resource.Record.t()`) so the regression shrinks
  rather than merely not growing (review-1 S-P5); the full R2 sweep stays
  with the packaging work.
- Re-run the example app suite (`example/todo_client`) — the RPC-counting
  router asserts wire silence on hits; Phase 1's select-widening changes what
  the source is asked for, and this suite is the flagship-consumer check.
  (The C4 end-to-end regressions live downstream — see Phase 4 acceptance.)
- Update `docs/technical/ash-multi-datalayer.md` (needed-fields definition,
  epoch protocol incl. seeding and check-insert-verify, source-half-only
  backfill on remainder reads, reconcile-on-record, evict-on-external-write,
  `forget!`) and add addendum lines to the review doc and C4 addendum marking
  C1–C4/M1 fixed at the fixing commit.
- Memory file update: v1 state note that the criticals are fixed.

## Explicit decisions taken by this plan (call out in review)

1. **Select-widening on backfilling source reads** (Phase 1) over a second
   fetch-for-backfill query: one source round trip, caller shape preserved by
   Ash's own narrowing; the alternative doubles source reads on every miss.
2. **Epoch granularity = resource+tenant**, not per-entry or per-row: the
   failure mode is recording coverage, which is resource+tenant-scoped;
   finer granularity buys nothing the `loaded_fields` gates don't already.
   The hit-rate cost under write load is acknowledged in Phase 3 and
   measured in Phase 6; the escape hatch, if ever needed, is narrower
   epochs — **not** conditional bumps.
3. **Zero-drop invalidations still bump the epoch** (rejecting review-1
   W-P2(c)): the original C3 repro *is* a zero-drop write (empty ledger for
   Q) racing an in-flight miss. Skipping the bump there reopens the exact
   reported bug.
4. **Stale-but-uncovered cache rows are left in place** (Phase 3): purging
   them would require knowing which rows the aborted read touched, and they
   are unservable by construction. The invariant is stated accordingly.
   (Phase 4's reconcile additionally cleans any such row that falls under a
   filter being freshly recorded.)
5. **Backfill and reconcile consume source-half rows only** on remainder
   reads (Phase 3.4/4.2): cache-origin rows are already present physically;
   re-upserting them risks NotLoaded clobber and ghost laundering, and
   deleting against a merged "fetched set" is unsound.
6. **Evict-on-external-update adopted, not destroy-only** (Phase 4.1): PK
   eviction is safe with partial payloads and closes the update variant at
   the API; the cost is a miss per externally-updated row. Reconcile remains
   as defense-in-depth (and covers the evict-failure residue), so both C4
   fixes still land together.
7. **Both C4 fixes land, not just evict-on-write** — with reconcile's reach
   stated precisely (rescoped per pass-4): evict-on-write closes the class
   at the API; reconcile cleans the evict-failure residue and any stale row
   under a region being freshly *re-recorded*. Neither is a safety net for
   sources that never call `on_write` — those need `forget!` (or LRU). The
   two still land together: the failure contract (swallowed evict errors)
   is only sound *because* reconcile exists behind it.

## Review disposition

| Finding (pass 1 / pass 2) | Disposition |
|---|---|
| C-P1 / F5 — epoch snapshot must precede the cache-side fetch on remainder reads | **Adopted** (Phase 3.1) + remainder race test (Phase 0.3) |
| C-P2 / F4 — reconcile/backfill must use source-fetched rows, never `merged` | **Adopted** (Phase 3.4, 4.2, decision 5) |
| F1 — record-side race: pre-checks don't cover insert-after-drop-scan | **Adopted**: check-insert-verify inside `Coverage.record` (Phase 3.3) |
| F2 — fingerprint dedupe never widens `loaded_fields` → permanent miss loop | **Adopted** (Phase 1) + narrow→wide→narrow property (Phase 6.1) |
| F3 — opaque probes reach the remainder split | **Adopted**: gate on `not probe.opaque?` (Phase 2) + pin test (Phase 0.5) |
| F6 — epoch must be seeded (absent ≠ 0), reset re-seeds | **Adopted** (Phase 3 mechanism) |
| F7 — evict on external updates too | **Adopted** (Phase 4.1, decision 6) |
| W-P1 / W-P5 / F8 — domain not in MDL `Info`; evict failure contract | **Adopted** (Phase 4.1) |
| W-P2(a,b) — state epoch hit-rate cost; measure it | **Adopted** (Phase 3 cost section, Phase 6.2) |
| W-P2(c) — skip bump on zero-drop invalidations | **Rejected** — reopens the original C3 repro (decision 3) |
| W-P3 — narrow-entry fragmentation | **Partially adopted**: F2 widening covers same-filter; cross-filter fragmentation accepted under the LRU cap (Phase 1) |
| W-P4 — reconcile "cache-local" is strategy-specific | **Adopted** (Phase 4.2 cost note) |
| W-P6 / F11 — epoch key sentinel collision | **Adopted**: 3-tuple meta key (Phase 3 mechanism) |
| F9 — downstream test path wrong repo | **Adopted** (Phase 4 acceptance) |
| F10 — "both partitions" ambiguous | **Adopted**: singular partition; M6 out of scope (Phase 3 mechanism) |
| F12 — BlockingLayer parks after delegating | **Adopted** (Phase 0.2) |
| S-P1..S-P6, F13 | **Adopted** (Phases 1, 5, 6.1, 7; F13 needs no change) |

Pass 3 and pass 4 (pass 4 adjudicates pass 3 where they overlap):

| Finding (pass 3 / pass 4) | Disposition |
|---|---|
| p3-W1 — reconcile placement decides whether it can be opaque-gated | **Adopted**: reconcile stays in `maybe_backfill` behind a shared public `Coverage` gate (recordable ∧ non-opaque); PK set stays out of `record`'s signature (Phase 4.2) |
| p3-W2 / p4-N1 — init/reset epoch seeding unimplementable; "absent ⇒ abort" breaks cold start | **Adopted**: atomic seed-at-snapshot via `update_counter` default; snapshot-time absence seeds, only check-time mismatch/absence aborts (Phase 3) |
| p4-adjudicated item "F1" — remainder reconcile "laundering" inside `C` | **Adopted as scoping, stronger remedies rejected**: the evict-failure sub-case cannot reach the cache half (dropped entries ⇒ ghost ∉ C); the forgotten-invalidation case is pre-existing staleness no recording creates and no local mechanism can detect. Decision 7 rescoped; pin test added (Phase 6.5) |
| p4-adjudicated item "F3" — PK-only `forget!` probe | **Adopted**: probe builds non-PK attrs as `%Ash.NotLoaded{}`, never `nil` + unit test (Phase 4.3); verified against the Ash evaluator by pass 5 |
| p3-S1 — fingerprint-widening metadata race | **Adopted as accepted-imprecision note** (last-writer union; transient misses, never staleness; no CAS) (Phase 1) |
| p3-S2 — `record` signature blast radius | **Adopted** (Phase 3.3 signature note) |
| p3-S3 — evict-on-local-update cost is strategy-specific | **Adopted** (Phase 4.1 cost note) |
| p4-N2 — "whole step skipped" too strong mid-reconcile | **Adopted**: tolerated-degradation wording (Phase 4.2) |
| p4-N4 — evict the before-image's PK | **Adopted** (Phase 4.1) |
| p4-N5 — disposition-table label W-P5 | **Adopted** (table above) |
| p4-N6 — kill-switch vs evict | **Adopted**: evict runs regardless (invalidation is never skippable); `WriteDispatch` moduledoc updated (Phase 4.1) |
| p4-N7 — epoch reads rescue-safe | **Adopted**: any epoch read failure ⇒ "moved" ⇒ abort/drop (Phase 3 mechanism) |

Label note (pass-5 trail / pass-6 F5, wording per pass-8 F4): "p3-F1"/"p3-F3"
were originally raised in review-3's *first published version*, which a later
session rewrote in place (it now carries W1/W2/S1–S3); pass 4 quoted and
adjudicated the originals before they vanished, so pass 4's adjudication
section is the surviving source for those two rows.

Passes 5–7:

| Finding | Disposition |
|---|---|
| p5-W1 — remainder reconcile needs `¬C`; nothing threads it into `maybe_backfill` | **Adopted**: `complement:` option threaded from `remainder_read` (nil ⇒ full-Q scan); recompute-in-place rejected — pass-8 F1 later established the recompute is *unsound*, not merely undisciplined (see the passes-8–10 table; Phase 4.2) |
| p5-S1 — epoch seed-or-read is an ETS write per miss-path read | **Adopted as acknowledged cost** + named read-mostly fallback (Phase 3 snapshot bullet) |
| p5-S2 — `bump_epoch` default must match the seed shape | **Adopted** (Phase 3 bump bullet) |
| p5 trail note / p6-F5 — disposition-table attribution | **Adopted**: label note above |
| p6-F1 — single seeded counter collides across restarts (`S2 == S1 + k`) | **Adopted**: epoch is a `{counter, incarnation}` pair, compared as a pair (Phase 3 mechanism) |
| p6-F2 — snapshot must `ensure_table` (calc-sort / non-mergeable paths never cache from cold start) | **Adopted** (Phase 3 snapshot bullet) |
| p6-F3 — seeding check-time reads make the absence clause dead text | **Adopted**: check-time reads are plain non-seeding lookups (Phase 3) |
| p6-F4 — double normalisation in the shared gate | **Adopted**: gate returns the normalised probe, passed into `record` (Phase 4.2) |
| p7-F1 — `bump_epoch` failure semantics unspecified on committed-write paths | **Adopted**: non-fatal, best-effort continue (Phase 3 bump bullet) |
| p7-F2 — C3 race-test assertion ordering (healing read re-records legitimately) | **Adopted**: no-entry assertion before any follow-up read (Phase 0.3) |
| p7-F3 — `touch` test seam not implementable as written | **Adopted**: `@doc false Coverage.touch/3` + `TestSupport.touch_entry!/3`, deliberately revisiting S-P3 (Phase 5) |

Passes 8–10 (files 8 and 10 are independent passes of the same version; file 9
sits between them):

| Finding | Disposition |
|---|---|
| p8-F1 — "entry set is stable across the guarded window" is false; recompute of `¬C` is unsound, not merely undisciplined | **Adopted**: justification replaced — scan region and fetch region must be the same object; the four bump-free entry-set mutators named (Phase 4.2) |
| p8-F2 / p10-S1 — two-step snapshot is not "atomic"; reset-mid-snapshot corner unspecified | **Adopted**: non-atomicity stated with its soundness argument (fetch follows snapshot); absence after seed attempt ⇒ abort (Phase 3 snapshot bullet) |
| p8-F3 — Phase 3.3 signature note stale after the p6-F4 adoption | **Adopted**: `record` gains `epoch0` + normalised probe; sections reconciled (Phase 3.3) |
| p8-F4 — trail wording (review-3's first version was overwritten, not never-existent) | **Adopted**: label note reworded |
| p9-F1/S1 — reconcile scan must strip `sort` (calc-sort branch) — full query shape named once | **Adopted**: filter-only reconcile query fully enumerated (Phase 4.2) |
| p10-S2 — non-fatal bump relies on bump+drops sharing one table | **Adopted**: assumption stated for the code comment; future store split must abort invalidation explicitly (Phase 3 bump bullet) |

Passes 11–12 (both: 0 mechanism defects, editorial only; both declare the plan
ready for Phase 0):

| Finding | Disposition |
|---|---|
| p11-S1 / p12-F3 — `maybe_backfill`'s final signature scattered across four bullets | **Adopted**: consolidated contract in Phase 3.5 |
| p11 note — reconcile scan-failure contract unstated | **Adopted**: skip reconcile, proceed to `record`, log + telemetry (Phase 4.2) |
| p12-F1 — p5-W1 disposition row contradicted p8-F1 ("despite being epoch-safe") | **Adopted**: row reworded |
| p12-F2 — "bump and drops fail together" is one-legged; recreated-table interleaving is closed by the incarnation | **Adopted**: two-legged invariant stated for the code comment (Phase 3 bump bullet) |
| p12-F4 — stale "seven plan reviews" count in the header | **Adopted**: count dropped from the prose |

---

**Last Updated**: 2026-07-05
