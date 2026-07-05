# Review — Plan: fix the critical findings (C1, C2, C3, C4, M1)

**Date:** 2026-07-05
**Scope:** `docs/plans/critical-bugs-fix-plan.md`
**Method:** verified every plan claim against the referenced review
(`20260704-implementation-review.md`), the C4 addendum, and the actual
implementation in `Coverage`, `DataLayer`, `Invalidation`, `Backfill`,
`Delegate`, `WriteDispatch`, `Info`, `Entry`, `TableOwner`, `ValueMerge`, the
test harness (`DataCase`, `CountingLayer`), and the repro artifact. Line
references below are to the current source unless prefixed `plan:`.

## Overall assessment

The plan is strong: the three invariants are stated precisely, the sequencing
(Phase 0 regression harness first; Phase 1 record/probe agreement "by
construction"; Phase 3+4 landing together) is correct, the residual-window
analysis for the full-miss path is rigorous, and the acceptance criteria are
tied to specific assertions. The C1 select-widening reasoning (Ash narrows to
the caller's select, same reason ETS returning full rows is fine —
`data_layer.ex:301-311`) checks out, and the Phase 1+Phase 2 combination is
sound *because* `force_change_attributes` never strips fields (a narrower
backfill can't clobber a fuller cached row — `backfill.ex` moduledoc).

The problems below are all about **partial reads**: Phases 3 and 4 reason
carefully about `source_read` (one fetch, one authoritative set) and then
hand-wave the same protocol over `remainder_read`, which has two fetches and a
blended result set. That is where the plan is not yet safe to implement.

## Findings

### Critical

- **C-P1. The epoch protocol is underspecified for `remainder_read` — stale
  cache-side rows can be backfilled and recorded.**
  `plan:159-167`, `data_layer.ex:786-806`. The plan says "Snapshot `epoch0`
  **before** the source fetch is issued." But `remainder_read` issues a
  **cache-side** fetch (`run_region(query, cache_layer, coverage)`) **before**
  the source-side fetch (`run_region(query, source_layer, complement)`), then
  merges both and passes the merge to `maybe_backfill`. A writer that
  invalidates in the gap *between the cache-side read returning and the
  source-side read starting* is invisible to an epoch snapshot taken "before the
  source fetch": `epoch0` already equals the post-write epoch, both re-checks
  pass, and the pre-write cache rows (potentially stale, potentially a C4 ghost)
  get upserted and recorded under fresh coverage. This is exactly the C3/M1
  invariant violation the phase exists to close, on a different read path.
  The snapshot must cover the **earliest** contributing fetch — i.e. before
  `coverage_split`/the cache-side `run_region`, not before the source-side one.
  Phase 0 must add a deterministic remainder-read interleaving test (not only
  the full-miss C3 test): reader runs the cache half and blocks → writer commits
  → reader resumes the source half → assert the merged/backfilled result and
  coverage reflect the write, not the stale cache rows.

- **C-P2. The reconcile step does not define which PK set is "authoritative" —
  on the remainder path it can launder cache ghosts.**
  `plan:211-216`, `data_layer.ex:791-803, 890-905`. The plan says reconcile
  deletes cached rows matching Q "whose PK is not in the fetched set." Today
  `remainder_read` passes `merged` (cache ∪ source, source-preferred) into
  `maybe_backfill/4`. If the reconcile derives its "fetched set" from that
  argument — the natural implementation — then a C4 ghost or stale row returned
  by the **cache half** is treated as "fetched" and survives reconciliation,
  after which `Coverage.record` promotes it into a full hit. The fix is to
  thread the **source-fetched rows only** (the `¬C` region result) as the
  authoritative PK set for reconcile, separate from the records being backfilled.
  Phase 0's C4 tests (a)/(b)/(c) must be run through the **remainder-read** path
  explicitly, not only the full-miss path — the plan currently implies
  re-covering reads but does not pin which read path covers them.

### Warnings

- **W-P1. Phase 4's "thread them from `Info`" is wrong for the domain — `Info`
  has no `domain` accessor.**
  `plan:206-208`, `info.ex`. `Info` exposes `read_layer_modules/1` and
  `write_layer_modules/1` but **not** `domain`. `Backfill.destroy_record/4`
  needs `domain:` in its opts (it builds a changeset with the domain set). The
  domain is available via `Ash.Resource.Info.domain(resource)` (confirmed in
  `deps/ash`), or must be threaded as an explicit parameter. The plan should
  name the actual source rather than implying `Info` provides it, otherwise the
  implementer hits a dead end mid-Phase-4.

- **W-P2. Bumping a resource+tenant epoch on every write will degrade cache
  effectiveness under write load, and the plan does not acknowledge the cost.**
  `plan:152-155, 288-290` (decision 2). The epoch is bumped unconditionally on
  every write (including no-op upserts — review N9) and the abort window is the
  full source round-trip. For the flagship remote-source composition the round
  trip is network-wide, so under modest write concurrency a large fraction of
  read-miss backfills will abort recording — coverage never warms, every read
  stays a miss. This is *correct* (decision 3's invariant holds) but it is a
  real performance hit the plan presents as free. Decision 2 justifies the
  granularity choice on correctness grounds only. Recommendation: (a) state the
  hit-rate trade-off explicitly; (b) have Phase 6's stress test **measure cache
  hit rate under write load**, not just the quiescence correctness assertion;
  (c) consider not bumping on writes whose `should_drop?` matched zero entries
  (a no-op invalidation currently still moves the epoch for every in-flight
  reader in that tenant).

- **W-P3. Phase 2's per-entry gate can fragment coverage and there is no
  widening/merge story.**
  `plan:124-128`. A legitimately-narrow entry that overlaps a wider query is
  excluded from `C`, forcing that region to the source. Correct, but narrow
  entries are the *norm* for the AshRemote flagship (wire field list derived
  from select). After a wider read re-backfills with `needed_fields` and records
  a new wider entry, the **narrow entry persists** and keeps excluding for every
  subsequent wider query — coverage fragments toward one-entry-per-select-shape
  and the `ledger_max_entries` cap (`coverage.ex:220-241`) fills with
  near-duplicate narrow entries. The plan should at minimum acknowledge this and
  consider recording a superset entry that subsumes the narrow one, or widening
  an existing entry's `loaded_fields` when its rows are re-fetched with more
  fields (the rows are already correct; only the gate is too strict).

- **W-P4. Phase 4's reconcile cost assumption ("cache-local") breaks for a
  non-local earlier layer.**
  `plan:214-216`. "One extra cache-layer pass per backfill — cache-local, never
  a source read" assumes the earlier layer is ETS/local. The orchestrator
  extraction this plan deliberately precedes
  (`20260705-orchestrator-behaviour-adr.md`) contemplates local-first
  strategies where the "cache" layer is itself remote relative to the node doing
  the reconcile. Reconcile then becomes a network round trip per backfill. The
  assumption is true for v1's caching strategy; the plan should state it as a
  strategy-specific assumption rather than a universal property, so a future
  strategy author knows to revisit reconcile.

- **W-P5. Phase 4 fix 1 (evict-on-destroy in `on_write/4`) has no failure
  contract.**
  `plan:202-210`, `backfill.ex:83-104`, `write_dispatch.ex:78-97`.
  `Backfill.destroy_record/4` can return `{:error, reason}`. Local writes call
  invalidation **after** the authoritative layer has committed, so an evict
  failure here cannot fail the write (that would violate FR3.5). The plan must
  state the contract: eviction failure is swallowed with warning + telemetry
  (mirroring `WriteDispatch.propagate/5`'s posture at `write_dispatch.ex:135-147`),
  does not affect the returned invalidation count, and the C4 ghost class then
  falls back to Phase 4 fix 2's reconcile-on-record. Without this, an
  implementer will either re-raise (breaking committed writes) or silently lose
  the C4 destroy guarantee.

- **W-P6. The epoch key `{:__epoch__, tenant_key}` can collide with an entry
  key for a tenant literally named `:__epoch__`.**
  `plan:146-149`, `coverage.ex:43-52`. The plan claims the shape "cannot
  collide with entry keys `{tenant_key, ref}` and is invisible to `entries/2`'s
  match spec." That holds for normal tenants, but `entries/2`'s match spec is
  `{{tenant_key(tenant), :_}, ...}` — a real tenant value of the atom
  `:__epoch__` matches the epoch row's key `{:__epoch__, tenant_key}`, returning
  the bare counter where an `%Entry{}` is expected, which crashes
  `& &1.normalised.disjuncts`. `tenant_key/1` does not reserve the sentinel.
  Low likelihood but the "cannot collide" claim is too strong. Use a key shape
  that structurally cannot match the entry pattern (e.g. a 3-tuple metadata key
  `{:__epoch__, tenant_key, :__mdl__}`), or reserve/validate against
  `:__global__`/`:__epoch__` in `tenant_key/1`.

### Suggestions

- **S-P1. Phase 1: the calculation-expression source differs between
  `query.calculations` and calc-sorts.** `plan:78-81`.
  `query.calculations` carries `{%Ash.Query.Calculation{}, expression}` tuples
  (the expression is the second element — `data_layer.ex:488`), but a calc-sort
  entry is `{%Ash.Query.Calculation{}, direction}` with no expression alongside;
  its expression lives in `calc.opts[:expr]` (`data_layer.ex:732-738`). The
  proposed `expression_attribute_refs/2` helper must read the expression from
  the right place for each case. Worth calling out so the helper doesn't
  silently return `[]` for calc-sorts (re-introducing the merged-read sort hole
  M5-style).

- **S-P2. Phase 1: verify `Ash.Filter.list_refs/1` handles `nil` expressions
  and relationship-path filtering as assumed.** `plan:67-71`.
  The plan's totality claim ("must stay total on degenerate input") depends on
  `list_refs/1` not raising on `nil`/empty filters and on the
  `relationship_path == []` filter correctly excluding related-path refs. A
  quick `iex>` check against the pinned Ash version before wiring it into the
  hot path would de-risk the "called on every read" invariant.

- **S-P3. Phase 5: prefer not to widen the public API for a unit test.**
  `plan:244-246`. The plan makes `touch/3` `@doc false` public purely for the
  unit test. The test can instead record an entry, drop it via
  `Invalidation.on_write/4` (or `Coverage.drop/3`), then `:ets.lookup` the
  table directly to assert the key is gone after calling the (still-private)
  `touch` through whatever exercise path already exists — or use a
  `defoverridable`/test-module wrapper. Avoids adding `@doc false` public
  surface for a one-off test.

- **S-P4. Phase 6: extend the field-modelling property to the merged-read local
  calc path.** `plan:250-255`. The C1 repro has two shapes (identical repeat
  read, and the `adult?` local-calc merged read). The proposed property covers
  cold/warm/wider-select but not the `merged_read` cache_query probe
  (`data_layer.ex:842-846`), which has its own `needed_fields` computation over
  `local_calcs`. A merged-read local-calc property closes the second C1 shape
  for free.

- **S-P5. Phase 7: add `mix format --check-formatted` and commit to fixing the
  R2-affected specs in the files this plan touches.** `plan:269-280`. The plan
  already lists test/integration/credo/dialyzer; formatting is the remaining
  standard gate. Separately, the plan touches `invalidation.ex` (Phase 3/4) and
  `backfill.ex` (Phase 4), both of which carry R2's `Ash.Resource.record()`
  spec regression — "use `Ash.Resource.Record.t()` in any touched spec" covers
  it implicitly, but listing those two files explicitly ensures the regression
  shrinks rather than merely not growing.

- **S-P6. Phase 4 `forget!/3` can reuse fix 1's mechanism.** `plan:223-230`.
  "Drop matching ledger entries (+ epoch bump)" for a PK means evaluating each
  entry's filter against the record — which is exactly
  `Invalidation.on_write/4(resource, tenant, record, nil)` plus
  `Backfill.destroy_record/4`. `forget!` is `on_write`-for-destroy + physical
  evict, i.e. fix 1 in a public wrapper. Naming this reuse avoids a parallel
  implementation and keeps the "single physical-invariant upholder" property
  the plan claims for `on_write/4`.

## What the plan gets right (verified)

- **Phase 1 record/probe agreement "by construction"** — both sides call
  `needed_fields(query, resource)` on the same query; the backfill `fields:` opt
  and the entry `loaded_fields` cannot drift. Confirmed against
  `data_layer.ex:890-905` and `coverage.ex:206, 121`.
- **`coverage_split/2` has exactly one caller** (`remainder_plan`,
  `data_layer.ex:771`), so widening it to `coverage_split/3` is contained.
- **Select-widening preserves caller shape** — the ETS precedent
  (`data_layer.ex:301-311`) holds: `%{query | select: wider}` is local, Ash
  projects to the original select. The plan's "add an explicit test anyway" is
  the right defensive move.
- **TableOwner crash resets the epoch to 0** — confirmed: `init` recreates the
  named table empty (`table_owner.ex:23-35`); a stale `epoch0 > 0` sees `0` and
  aborts (decision: conservative, correct).
- **Phase 0 repro is `@moduletag :integration`-compatible** — `DataCase.using`
  sets the tag itself (`data_case.ex:14-23`); the artifact already `use`s it.
- **Phase 5's `update_element` positional logic** — the ETS object is
  `{{tenant_key, id}, entry}`, so `{2, entry}` targets the entry correctly.

## Summary

2 critical, 6 warnings, 6 suggestions.

The plan's full-miss reasoning (Phases 1, 2, 5, and the `source_read` half of
Phases 3/4) is sound and implementable as written. The blocking gap is that the
same protocols (epoch snapshot; reconcile's authoritative PK set) are specified
only for the single-fetch path and then implicitly assumed to carry over to
`remainder_read`, which has two fetches and a cache/source blend. Until the
epoch snapshot covers the earliest fetch and reconcile is fed the
source-fetched set explicitly, Phases 3 and 4 will close the repros without
closing the invariant on the remainder path. The warnings are mostly
acknowledged-trade-offs the plan should state openly (epoch hit-rate cost,
narrow-entry fragmentation, reconcile-on-remote-layer cost) plus one
implementation dead-end (`Info.domain`) and one contract gap (evict failure
semantics).

---

**Last Updated**: 2026-07-05
