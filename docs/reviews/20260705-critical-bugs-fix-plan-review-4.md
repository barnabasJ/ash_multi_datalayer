# Plan Review (fourth pass) — the amended critical-bugs-fix-plan.md

**Date:** 2026-07-05 **Scope:** the amended
`docs/plans/critical-bugs-fix-plan.md` (the version carrying the Review
disposition table), reviewed against both prior passes
([pass 1](./20260705-critical-bugs-fix-plan-review.md),
[pass 2](./20260705-critical-bugs-fix-plan-review-2.md)) and the source. This
pass was produced independently of, and completed after,
[pass 3](./20260705-critical-bugs-fix-plan-review-3.md); a section below
adjudicates pass 3's findings where the two passes overlap or disagree.
**Method:** every disposition-table row was checked against the finding it
disposes and the plan text that claims to implement it; the new mechanism text
(3-tuple epoch key, seeding, check-insert-verify, source-half-only
backfill/reconcile, evict-on-update, `forget!`-as-wrapper) was re-derived
interleaving by interleaving, the same way as pass 2.

**Verdict:** the amendment is faithful. All 20 pass-1/pass-2 findings are
correctly dispositioned; the adopted fixes say what the reviews meant, and the
one **rejection** — W-P2(c), skipping the epoch bump on zero-drop invalidations
— is correct and important: the original C3 repro is exactly a zero-drop write
racing an in-flight miss, and this pass independently re-derived the same
conclusion. The check-insert-verify wording, the source-half-only rule, the Q∧¬C
reconcile restriction, and the 3-tuple key are all sound as specified.

One defect was introduced by the F6 adoption (N1 — the epoch seeding mechanism
cannot be implemented as written; pass 3's F2 found the same hole, and this pass
adds the concrete fix and the acceptance-test contradiction). The rest is
wording-level, plus two pass-3 findings whose severity this pass argues down
with mechanics.

---

## Verified: dispositions and new mechanisms

- **All 20 findings accounted for.** C-P1/F5, C-P2/F4, F1, F2, F3, F6, F7,
  W-P1/W-P5/F8, W-P2(a,b), W-P3, W-P4, W-P6/F11, F9, F10, F12, F13, S-P1–S-P6 —
  each maps to concrete plan text in the phase the table names. (Table nit: N5
  below.)
- **W-P2(c) rejection endorsed.** `should_drop?` matching zero entries is the
  _ledger-empty-for-Q_ case — the reported bug's precondition. Decision 3 is
  exactly right.
- **Check-insert-verify (Phase 3.3)** matches pass-2 F1's closure argument,
  including the two-sided case analysis (bump-before-verify ⇒ self-drop;
  bump-after-verify ⇒ the writer's own drop-scan sees the entry), and correctly
  extends the same discipline to the fingerprint-widening path.
- **3-tuple key `{:__mdl_meta__, :epoch, tenant_key}`** is structurally
  unmatchable by `entries/2`/`size/2`'s `{{tenant, :_}, …}` patterns for any
  tenant term — stronger than both prior suggestions.
- **Source-half-only backfill (Phase 3.4) with full-Q recording is sound**:
  Phase 2's gate guarantees every entry contributing to `C` holds
  `loaded_fields ⊇ needed(query)`, so the covered half's rows already physically
  contain what the recorded entry claims; nothing needs re-upserting for them.
- **`forget!` as an `on_write` wrapper (Phase 4.3)** is the right factoring —
  with evict-on-update adopted, `on_write` is the single upholder of the
  physical invariant. (PK-only calls need one implementation caveat — see the
  pass-3 F3 adjudication.)
- **Phase 5's `TestSupport` seam exists**
  (`lib/ash_multi_datalayer/test_support.ex`) — the reference is real.
- **Phase 0 amendments** (park-after-delegate, remainder race shape,
  C4-through-both-paths, the F3 pin test) all match what the reviews asked for.

---

## N1 (must fix; = pass-3 F2): the epoch seeding mechanism is unimplementable as specified, and "absent ⇒ abort" breaks cold-start caching

Phase 3's mechanism says: "`TableOwner.init` seeds each table's epoch space with
`System.unique_integer(...)`, and `Coverage.reset/1` re-seeds. A reader must
treat an _absent_ epoch as 'abort caching', never as `0`."

Three problems, one root cause — epochs are **per-tenant** and tenants are
unknown ahead of time:

1. `TableOwner.init` cannot seed per-tenant keys: the table is created empty
   (`table_owner.ex:24-35`) and the tenant set is unbounded and lazy. There is
   no "epoch space" to seed at init.
2. `Coverage.reset/1` has the same problem after `delete_all_objects` — it
   cannot know which tenant epochs to re-create.
3. With seeding impossible, "absent ⇒ abort caching" does real damage: the only
   bumpers are `on_write`/`drop_all`, so on a **read-only cold start** — the
   most cache-friendly workload there is — every tenant's epoch is absent on
   every read, every backfill aborts, and coverage never records. This
   contradicts Phase 1's own acceptance gate (cold read → record → "the second
   read is asserted to be a coverage **hit**"): once Phase 3 lands, that test
   fails against a fresh table with no writes.

**Fix (stays entirely within the plan's design): seed lazily and atomically at
snapshot.** Make the snapshot read itself the seeder:

```elixir
# Coverage.epoch/2 — used for both the snapshot and the check-time reads
:ets.update_counter(table, key, 0, {key, System.unique_integer([:positive])})
```

`update_counter` with a default is atomic insert-if-absent-then-read: the first
reader of a partition seeds a fresh unique value and proceeds; a concurrent
second reader gets the first's value (no torn seeds); writers bump with the same
shaped default. `System.unique_integer([:positive])` never repeats for the
node's lifetime, so after a TableOwner crash-restart _or_ a `reset/1`, the next
access seeds a value no pre-crash snapshot can equal — every in-flight reader's
check mismatches and aborts, which is exactly the conservatism pass-2 F6 wanted,
without init-time seeding, without a reset re-seed step, and without the
cold-start regression. ("Absent" at check time can then only mean the table died
between snapshot and check — abort, as the plan already says.) Plan-text
consequences: drop the `TableOwner.init`/`reset/1` seeding sentences (and
`table_owner.ex` from Phase 3's file list unless something else needs it); state
that snapshot-time absence _seeds_ while only mismatch-or-absence at **check**
time aborts.

---

## Adjudication of pass 3's findings

- **Pass-3 F1 (rated critical there): remainder reconcile scans Q∧¬C but records
  all of Q — stale rows inside `C` get "laundered".** The scenario is real but
  narrower than pass 3 states, and the strong remedies are disproportionate:
  - The **evict-failure sub-case does not exist.** If `on_write` ran and only
    the evict failed, the entries were already dropped — and every entry whose
    filter matched the ghost (its values are a before-image) is gone, so the
    ghost satisfies no surviving entry's filter, hence does not satisfy `C` (the
    union of surviving entries' filters), hence **cannot be returned by the
    cache half** of any remainder read. The evict-failure residue is reachable
    only through _re-recording over the ghost's region_, which is the
    full-miss/`¬C` reconcile — already covered.
  - What remains is the **forgotten-invalidation** case (no `on_write` at all):
    the ghost's covering entry survives, so the ghost is served by plain covered
    reads _already, today, with or without the new entry_ — recording Q adds a
    second covering claim but does not create the staleness, and reads of Q ⊆
    old-entry-region would mostly be **full hits** that never reach the
    remainder path or any reconcile anyway. No local mechanism can distinguish
    untold staleness under valid coverage from freshness; pass 3's stronger
    options (refuse to record full Q from remainder reads / add a PK-only full-Q
    source read per remainder backfill) pay a real, permanent cost — the second
    option doubles source round trips on every remainder backfill — to shrink a
    window that the surviving old entry holds open regardless.
  - **Disposition this pass recommends:** pass 3's fix option 3 = pass 2's N3:
    scope decision 7 honestly (reconcile covers the evict-failure residue and
    regions being re-recorded; it is _not_ a safety net for invalidation sources
    that never call the API — for those, `forget!` and eventual LRU/invalidation
    are the only healers), and add pass-3 S1's test pinning which class
    reconcile does close. Severity: wording/scoping, not a blocking design flaw.
- **Pass-3 F3: `forget!` with a bare PK "cannot know which entries to drop".**
  Overstated, but it points at a real implementation trap. The conservative
  matcher already handles sparse rows — `matches_or_unknown?` drops on
  `:unknown` — **provided the probe record's non-PK fields are
  `%Ash.NotLoaded{}`**. The trap: building the probe with plain `nil`s makes
  filters _evaluate_ instead of returning unknown (`age > 5` over `age: nil` is
  a definite non-match under Ash's nil semantics), so an entry whose region
  contains the row's true state survives the drop while `forget!` evicts the
  physical row — a covered read of that region then silently loses the row. One
  sentence in Phase 4.3 closes it: _a PK-only `forget!` must construct the probe
  record with non-PK attributes as `%Ash.NotLoaded{}` (never `nil`), so filter
  evaluation degrades to `:unknown` → conservative drop._ Worth a unit test
  asserting a PK-only `forget!` drops an entry whose filter references a non-PK
  field.
- **Pass-3 F2** = N1 above; convergent. This pass adds the concrete
  atomic-seed-at-snapshot API and the Phase 1 acceptance-gate contradiction.

---

## Wording-level items (not raised by pass 3)

- **N2 — "the whole reconcile+record step is skipped" is slightly too strong**
  (Phase 4.2, epoch-guard bullet). That holds only when the concurrent write's
  bump lands before the pre-reconcile check. If the bump lands _mid-reconcile_,
  the reconcile can still delete a concurrently-propagated fresh row; the record
  insert is then skipped by check/verify, so the outcome is a later cache miss
  on that row — degradation, never staleness. Safe, but the promised code
  comment should describe it as tolerated degradation rather than an
  impossibility, or an implementer will "fix" the wrong thing when they observe
  it.
- **N4 — evict-on-update: name the PK image.** "Evict by PK as well" — specify
  the **before-image's** PK. For a PK-changing external update, evicting the
  after-PK leaves the stale before-PK row in place; the before-PK row is always
  the stale one, and the after-PK row is healed by normal upsert/refetch.
- **N5 — disposition-table row label.** The row "W-P1 / F8" actually disposes
  W-P1 (domain source) **and W-P5** (evict failure contract) — W-P5 otherwise
  appears nowhere in the table, though Phase 4.1 cites it. Fix the label so the
  audit trail stays 20/20.
- **N6 — kill-switch contract touch.** Fix 1 makes `Invalidation.on_write` write
  to cache layers (evict), and `WriteDispatch` runs invalidation even with the
  kill switch tripped — so "kill-switch engaged: only the authoritative write
  happens … propagation is skipped" (`write_dispatch.ex:19-21`) becomes
  inaccurate. Both behaviours are safe (skipping the evict during kill-switch
  leaves only uncovered rows for later backfill/reconcile to clean; running it
  keeps the cache cleaner). Pick one deliberately and update the WriteDispatch
  moduledoc.
- **N7 — verify-path rescue posture.** Check-insert-verify inside
  `Coverage.record` adds ETS reads/deletes that can raise `ArgumentError` if the
  table dies mid-sequence; per the implementation review's N3, `insert` already
  lacks the rescue its siblings have. One sentence in Phase 3: any epoch
  read/verify failure is treated as "moved" (abort/drop, rescue-safe) — never a
  crash on the caller's read path.

---

## Summary

1 must-fix (N1, convergent with pass-3 F2 — replace init/reset seeding with
atomic seed-at-snapshot; snapshot-time absence seeds, only check-time mismatch
aborts), 2 pass-3 findings adjudicated down to scoping/implementation notes (F1
→ scope decision 7 + pin test; F3 → NotLoaded-not-nil probe rule + unit test), 5
wording-level. All prior findings are correctly incorporated; the single
rejection is correct. With N1 amended and the decision-7 scoping applied, the
plan is safe to implement as sequenced — nothing in this pass touches the phase
structure or the acceptance gates beyond the additions named above.

---

**Last Updated:** 2026-07-05
