# Plan Review (second pass) — critical-bugs-fix-plan.md (C1–C4, M1)

**Date:** 2026-07-05 **Scope:** `docs/plans/critical-bugs-fix-plan.md`, reviewed
against `lib/` at the current working tree, the 2026-07-04 implementation
review, the C4 addendum, the repro artifact, and the downstream
`../ash_remote_cache` code the plan folds back. **Method:** every code citation,
line number, API-existence claim, and race analysis in the plan was checked
against the actual source; the residual-race arguments in Phases 3–4 were
re-derived interleaving by interleaving. **Relation to**
[`20260705-critical-bugs-fix-plan-review.md`](./20260705-critical-bugs-fix-plan-review.md)
(an earlier independent pass): this review was produced without reading it and
converges with it on three findings — remainder-read epoch snapshot placement
(its critical #1 = F5 here), eviction failure semantics (its warning #2 = F8),
and the `:__epoch__` tenant sentinel collision (its warning #1 = F11). Its
critical #2 (the reconcile pass must not derive its "fetched set" from `merged`)
is adopted into F4 below. Findings F1, F2, F3, F6, F7 here are additional.

**Verdict:** the plan is well-grounded and correctly sequenced — every file/line
citation is accurate, Phase 2 is correctly identified as not subsumed by Phase
1, the epoch key orientation is right, and the harness-first ordering with the
repro artifact as acceptance gate is the right structure. Two findings need plan
changes before implementation (P1): the epoch protocol as specified does **not**
close the record-side race it claims to close, and `Coverage.record`'s
fingerprint dedupe silently defeats Phases 1–2 for narrow-then-wide workloads.
The rest are spec-precision items and decisions to record. Nothing requires
re-architecting; all fixes fit inside the plan's existing phases.

---

## Verified accurate

- Every cited location checks out: `needed_fields/2` at `coverage.ex:244-251`,
  `coverage_split/2` at `coverage.ex:140-155`, `touch` at `coverage.ex:269-271`,
  `remainder_plan` at `data_layer.ex:769-784`, `cache_query` carrying local
  calcs at `data_layer.ex:842-845`, the ETS full-rows comment at
  `data_layer.ex:303-311`.
- `Ash.Filter.list_refs/1` exists (`deps/ash/lib/ash/filter/filter.ex:2659`).
- The epoch key orientation `{:__epoch__, tenant_key}` is the only safe shape:
  the reverse, `{tenant_key, :__epoch__}`, **would** leak the counter into
  `entries/2`'s match spec for every tenant. (The residual sentinel collision is
  F11.)
- Phase 5's `:ets.update_element(table, key, {2, entry})` targets the right
  element position (objects are `{key, entry}`).
- Phase 2's citation of partial-serving plan rule 4 is accurate
  (`partial-serving-remainder-reads-plan.md:65`), and the "not subsumed by Phase
  1" argument is correct — `covers?` already gates `loaded_fields` on full hits
  (`coverage.ex:162`), so gating `coverage_split` restores symmetry.
- Phase 0's prerequisites exist: `test/support/counting_layer.ex`,
  `test/support/generators.ex`, and the repro artifact's resources (`TestPost`,
  `MirrorPost` sharing `mdl_posts`) are present; the three artifact tests match
  the review's described scenarios.
- Phase 4 fix 1's dependency holds: `Backfill.destroy_record/4` exists and the
  layers are reachable from `Info` (`info.ex:17,48,54`). (The domain is _not_ in
  `Info` — see F8.)
- Decision 1 (select-widening over a second fetch) is sound and consistent with
  the existing ETS-returns-full-rows precedent; `merged_read`'s miss path routes
  through `source_read`, so the widening covers it too.

---

## P1 — plan changes required before implementation

### F1. The check-before-record does not close the record-side race; the plan's restored invariant is still violated in one window

Phase 3's protocol is snapshot → check-before-upsert → upsert →
check-before-record → record. The "residual window" analysis (plan lines
173-183) only considers a writer landing **between check 2 and the upsert**, and
correctly argues the resulting stale row is uncovered. It does not consider the
symmetric window: the writer's `bump → drop → propagate` sequence landing
**between the final epoch check and the ETS insert inside `Coverage.record`**.
In that window the reader inserts a coverage entry computed from pre-write rows
_after_ the writer's invalidation drop — coverage resurrection, the same class
M1 fixes for `touch`.

When the writer's propagation then **fails** (the precise case
`write_dispatch.ex:10-17` names as the design point of
invalidation-before-propagation), the cache physically holds pre-write rows
under a live coverage entry → persistent stale hits. This directly contradicts
the plan's own stated restored invariant: "**no coverage entry ever claims
pre-write state**".

**Fix (small, fits Phase 3):** check-insert-**verify**. After `Coverage.record`
inserts, re-read the epoch a third time; if it moved, drop the just-inserted
entry (by its id). This closes the window deterministically: if the writer's
bump happens _before_ the verify, the reader deletes its own entry; if the bump
happens _after_ the verify, the insert happened before the writer's drop-scan
(`Invalidation.on_write` enumerates `entries/2` after the bump), so any entry
whose filter the changed row matters to is dropped by the writer itself. No
interleaving is left in which a pre-write entry survives. Implementation note:
this is easiest if the epoch discipline moves _into_ `Coverage.record` (pass
`epoch0`), since `record` internally does dedupe-scan → cap-evict → insert and
the check must bracket the insert, not the whole of `maybe_backfill`.

### F2. `Coverage.record`'s fingerprint dedupe never widens `loaded_fields` — narrow-then-wide same-filter workloads become a permanent miss loop

`record` returns `:ok` without touching the existing entry when the fingerprint
matches (`coverage.ex:192-194`). After Phases 1–2, this sequence is a
designed-in permanent performance hole:

1. Narrow read records entry E for filter F with `loaded_fields = {id, name}`.
2. A wider read of the same F needs `{id, name, age}` → `covers?` misses
   (`:fields_insufficient`); Phase 2's gate excludes E from `C` → full
   `source_read` with widened select → backfill physically writes `age` into the
   cached rows → `Coverage.record` → **fingerprint matches E → skip**.
3. E still claims `{id, name}`. Step 2 repeats on every wider read, forever —
   the C2 acceptance scenario (a) passes its test but stays uncached
   permanently, with a full source round trip each time.

**Fix (one clause, belongs in Phase 1 or 2):** on fingerprint match, union the
query's `needed_fields` into the existing entry's `loaded_fields`. This is sound
exactly because the backfill that just ran wrote that field set into the
physical rows — and it must therefore sit inside the same epoch guard as the
insert path (a widened `loaded_fields` claim from an aborted backfill would be a
field-level C3). Phase 6's field-modelling property should cover the
narrow→wide→narrow sequence to pin this.

---

## P2 — should be addressed in the plan text

### F3. Remainder-path splitting of solver-opaque probes bypasses every field gate the plan builds

`remainder_plan` runs on **any** miss reason, including `:solver_unsupported`
(`data_layer.ex:753-760`) — an opaque probe still gets split against `C` and its
covered half evaluated by the cache layer. Both of the plan's field gates are
computed from `needed_fields`, which (per the Phase 1 spec) sees only top-level
attribute refs. The plan's own parenthetical ("filters containing [calc/related
refs] are opaque to the normaliser — never recorded, never a hit — so they
cannot demand local evaluation") is true for the _full-hit_ path and false for
the _remainder_ path:

- A filter embedding a calculation ref (if such filters reach the data layer
  unexpanded — the parenthetical presumes they do) has the calc's **input
  attributes** in no field set anywhere: they are not attribute refs of the
  filter and not in `query.calculations`. The cache layer evaluates the calc
  over rows that may lack its inputs → nil → silent row loss from the covered
  half — the C2 failure shape, surviving the C2 fix.
- A related-path filter demands related-row freshness this resource's ledger
  says nothing about (likely unreachable given `can?({:join, _}) == false`, but
  nothing pins that).

**Fix:** gate `remainder_applicable?`/`remainder_plan` on `not probe.opaque?`
(the probe is already computed in `covers?`; thread it or re-normalise). Cost:
opaque filters fall through whole to the source — which they already do for full
hits, and they can never record coverage anyway, so the lost cache benefit is
marginal and the posture matches the project's "conservative on unknown" rule.
At minimum, Phase 0 should add a repro-attempt test for the calc-ref-in-filter
shape so the parenthetical's assumption is pinned rather than presumed.

### F4. Backfilling `merged` re-upserts cache-origin rows — an N8 landmine, and it poisons the reconcile pass's "fetched set"

`remainder_read` passes `merged` (cache rows + source rows) to `maybe_backfill`
(`data_layer.ex:802`). Two consequences:

1. **NotLoaded clobber behind a select-pushing cache layer.** The cache-side
   region read replays the caller's **narrow** `query.select`; Phase 1 widens
   only the _source_ side. A cache layer that honours select returns narrowed
   structs, and backfill's `Map.take(record, fields)` over the widened field
   list copies the missing fields as `%Ash.NotLoaded{}` through
   `force_change_attributes` — clobbering good cached values with sentinels
   (review N8's exact mechanism, on a new path). ETS ignores select today, so
   this is latent — but MDL is layer-agnostic by contract.
2. **Reconcile set contamination** (= the earlier review's critical #2): if
   Phase 4's reconcile derives "the fetched set" from the records handed to
   `maybe_backfill`, cache-origin rows count as fetched. In the
   forgotten-invalidation scenario the reconcile pass exists for (a ghost still
   inside a surviving entry's region), the ghost arrives via the cache half of
   `merged`, survives reconciliation as "fetched", and `Coverage.record`
   launders it into a full hit.

**Fix (one change addresses both):** backfill and reconcile against the
**source-fetched rows only** — cache-origin rows are already physically present,
so nothing about recording Q requires re-upserting them, and the reconcile's
authoritative PK set is then source-only by construction for `source_read`; for
`remainder_read` the reconcile must additionally treat the cache half's region
as unreconcilable (or intersect with `¬C` when deleting). Alternatively, thread
the source-row PK set separately from the backfill records. Either way the plan
should say which; today it doesn't.

### F5. Phase 3's snapshot point must precede the _cache_-side region read, not just "the source fetch"

(Converges with the earlier review's critical #1.) In `remainder_read` the cache
region read runs first and its rows are also backfilled as part of `merged`.
Interleaving: reader's cache fetch returns a pre-write row → writer commits,
invalidates, propagates the fresh row into the cache → reader's source fetch (of
`¬C`, which doesn't contain this row) completes → reader re-upserts the stale
cache-origin row over the writer's fresh propagation, and records. Snapshotting
"before the source fetch" misses this. The spec should read: snapshot at the top
of `remainder_read` (and of `source_read`), before any layer is consulted.
Adopting F4's backfill-source-rows-only also eliminates this particular vector,
but the snapshot placement should still be stated correctly, and Phase 0 should
add a remainder-shaped interleaving test alongside the full-miss C3 test.

### F6. The epoch-reset analysis covers `epoch0 > 0` but not `epoch0 == 0` — seed the epoch, don't default it

Plan: "a reader holding a pre-crash `epoch0 > 0` sees `0 ≠ epoch0` and skips —
conservative, correct." True, but the fresh-table case is not: reader snapshots
an absent epoch as `0` → writer bumps to 1, drops, propagates → TableOwner
crashes and restarts (epoch absent → `0` again) → reader's check passes `0 == 0`
→ stale backfill **and** stale record into the fresh ledger. `Coverage.reset/1`
(`delete_all_objects`) reintroduces the same hole without a crash. **Fix:** seed
the epoch at table creation (TableOwner init) with
`System.unique_integer([:positive, :monotonic])` and re-seed in `reset/1`; then
any restart or reset observably changes the value. Keep "absent" on the reader
side as "abort caching", not "0".

### F7. Phase 4 fix 1 should evict on external _updates_ too — or the plan should record why not

Decision 4 says "fix 1 alone leaves the update variant open" — but that is a
consequence of scoping fix 1 to destroys, not a property of eviction. `on_write`
with a changed `row_after` (external update) could `Backfill.destroy_record` the
row by PK just as safely: eviction needs only the PK (safe with partial
notification payloads, unlike upserting a possibly partial after-image, which
would hit N8), and after the entry drops nothing covers the row in either its
old or new region, so its absence is a miss, not staleness. That closes the
update variant _at the API_, immediately, with the reconcile pass demoted to
pure defense-in-depth — strictly stronger than reconcile-only, which fixes the
region being _re-recorded_ while leaving the ghost value servable under any
other surviving entry's region until then. Cost: one cache miss per
externally-updated row, which is what correctness costs. If there is a reason to
reject this (e.g. update-heavy notification streams hollowing out the cache),
decision 4 should record it explicitly.

### F8. `on_write`'s new cache writes need an explicit error policy, and "from `Info`" is half-right

(Converges with the earlier review's warning #2.) Fix 1 makes
`Invalidation.on_write` perform cache-layer destroys. The plan must state:
eviction failure is non-fatal (log + telemetry, continue) — `on_write` is called
inline from `WriteDispatch.invalidate` after the authoritative write has already
committed, and from external notification handlers; neither may crash or fail
the surrounding operation. The residue of a failed evict (ghost row, entries
already dropped) is exactly what the Phase 4 reconcile pass cleans — worth
saying, since it is one more reason fixes 1 and 2 land together. Also a wording
fix: the plan says to thread "the layers/domain … from `Info`" — layers yes, but
the domain comes from `Ash.Resource.Info.domain(resource)`, not
`AshMultiDatalayer.DataLayer.Info`.

---

## P3 — minor / editorial

- **F9 — wrong repo in Phase 4 acceptance.** The cited regression tests
  (`example/todo_client/test/todo_client/live_test.exs:52`, `:90`) live in the
  **downstream** repo — `../ash_remote_cache/example/todo_client/…` ("deleting a
  row a different actor already destroyed self-heals…"). This repo's file at
  those lines is unrelated CRUD/aggregate tests. Fix the path so Phase 7's
  runner doesn't tick the wrong suite.
- **F10 — "both partitions they touch" is ambiguous** (Phase 3). `on_write` and
  `drop_all` touch exactly one partition today. If the intent is to bump the
  tenant **and** `:__global__` epochs, that is a deliberate slice of M6 and
  should be stated as such; if not, reword to "the partition they touch".
- **F11 — sentinel-tenant collision.** (Converges with the earlier review's
  warning #1.) A tenant literally equal to `:__epoch__` makes
  `entries(resource, :__epoch__)` match epoch counter rows and return raw
  integers to callers expecting `%Entry{}`. Same pre-existing class as a tenant
  named `:__global__`; one guard or doc line covers both.
- **F12 — BlockingLayer must block _after_ delegating.** Phase 0.2's harness
  reproduces C3 only if `run_query` captures the target's (pre-write) result,
  _then_ parks on the test-process message, _then_ returns the captured rows.
  Blocking before delegation would fetch post-write values on resume and the
  race would not reproduce. One sentence in the plan prevents building the
  harness wrong and misreading the C3 test as passing.
- **F13 — FYI, no change needed:** `Debug` (`debug.ex:39,45`) computes
  `needed_fields` and the subset check itself, so Phase 1's widening flows into
  `ash_multi_datalayer.inspect` automatically — correct; noting only that the
  file is absent from Phase 1's list because it genuinely needs no edit.

---

## Acceptance-criteria notes

- Phase 1's "second read asserted to be a coverage **hit** (telemetry)" is the
  right bar — keep it; it is what catches fixed-by-falling-through. After F2's
  loaded-fields widening lands, add the same telemetry-kind assertion to the C2
  acceptance (a): the _third_ wide read should then be a hit.
- Phase 3's race test asserts the post-race read returns the written value; with
  F1's verify step, extend it to also assert **no ledger entry exists for Q** at
  quiescence when the writer wins (the entry-resurrection shape), not just value
  freshness.
- Phase 6.2's quiescence invariant ("every recorded filter re-run against the
  cache equals the source") is exactly the right property and would have caught
  F1 — worth running with the writer mix biased toward propagation-failure
  injections (the F1 window) once the blocking layer exists.

## Summary

2 P1 (F1 record-side epoch race not closed; F2 dedupe never widens
`loaded_fields`), 6 P2, 5 P3. Three P2/P3 findings and one P2 sub-point
independently confirm the earlier review pass. The plan's structure, phase
boundaries, and acceptance gates are sound; land the P1/P2 amendments in the
plan text before Phase 0 starts, since several change what the Phase 0 tests
must assert.

---

**Last Updated:** 2026-07-05
