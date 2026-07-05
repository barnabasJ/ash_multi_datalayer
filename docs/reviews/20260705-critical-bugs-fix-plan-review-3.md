# Plan Review (third pass) — critical-bugs-fix-plan.md (amended)

**Date:** 2026-07-05
**Scope:** the amended `docs/plans/critical-bugs-fix-plan.md` (the version with
the Review disposition table and F1–F13 amendments from passes 1–2).
**Method:** re-derived every amended race argument interleaving-by-interleaving
against the current `lib/` source; verified each amendment's code-placement
claim and the new acceptance assertions. Read both prior reviews first; this
pass looks for (a) amendments that don't fully close what they claim, (b) new
gaps the amendments introduce, and (c) anything both prior passes missed.

**Verdict:** the amendments land. F1's check-insert-verify closes the
record-side race (verified across every bump-before-verify / bump-after-verify
interleaving — including the propagate-fails case), F4's source-half-only
backfill is sound, F7's evict-on-update is correct at the API, decision 3's
rejection of zero-drop-bump is right (C3 *is* a zero-drop case), and the 3-tuple
meta key fully resolves the sentinel collision. Two items still need plan-text
changes before Phase 0 starts (both about *where* the reconcile/epoch logic
physically sits), plus a few precision notes. Nothing re-opens a closed finding.

---

## Verified sound (amendments re-derived, not just trusted)

- **F1 — check-insert-verify.** Snapshot `epoch0` → check-before-upsert →
  (upsert) → inside `Coverage.record`: check → insert → re-read → drop-if-moved.
  Exhaustively: if the writer's bump lands before the verify, the reader deletes
  its own entry; if it lands after the verify, the insert preceded the bump so
  the writer's `on_write` drop-scan (which enumerates *after* bumping — confirmed
  `invalidation.ex:61-67` scans `entries/2` after the bump) sees and drops it.
  No interleaving leaves a pre-write entry alive. The propagate-fails case (the
  design point of invalidate-before-propagate) is covered because the entry is
  gone either way. Correct.
- **F4 — backfill consumes source-half rows only.** Sound: cache-origin rows are
  already physical (that's what "covered" means), Phase 2's gate guarantees the
  contributing entry's rows carry ⊇ `needed` fields, and skipping the re-upsert
  kills both the N8 NotLoaded-clobber vector and the ghost-laundering vector in
  one stroke.
- **F7 — evict-on-external-update.** PK eviction is safe with partial payloads
  (unlike upserting a partial after-image) and closes the update variant at the
  API immediately. For *local* writes the evict is immediately undone by
  `WriteDispatch.propagate` — redundant churn, not a correctness issue (I
  checked: between evict and propagate the entries are already dropped, so a
  concurrent read misses to source regardless).
- **Decision 3 — zero-drop invalidations still bump.** Correctly justified: the
  original C3 repro is an empty-ledger write (nothing to drop) racing an
  in-flight miss. Skipping the bump there reopens the reported bug.
- **F2 — fingerprint widening.** Sound and sits inside the same epoch discipline
  (check → `update_element` → verify → drop-on-move). Defuses the
  narrow-then-wide permanent-miss loop.
- **F3 — opaque probes never split.** Correct; `remainder_plan` running on
  `:solver_unsupported` was the gap. Thread the miss `reason` from `covers?`
  (cheaper than re-normalising).
- **Reconcile restricted to Q ∧ ¬C on the remainder path.** Verified the
  soundness claim: after invalidation, no *surviving* gated entry's filter can
  match a stale/ghost before-image (`should_drop?` drops any entry whose filter
  matches the before-image or after-image — `invalidation.ex:31-37`), so the
  ghost's region is not in `C` and the cache half cannot serve it. Restricting
  reconcile to ¬C is therefore both safe and necessary (the covered half's rows
  are legitimately absent from the source fetch).
- **3-tuple meta key `{:__mdl_meta__, :epoch, tenant_key}`.** Confirmed safe
  for any tenant value: `entries/2`'s match pattern `{{tenant, :_}, ...}` is a
  2-tuple key; a 3-tuple key structurally cannot match it. Resolves F11/W-P6
  including the pathological `:__mdl_meta__` tenant.

---

## Warnings (plan-text changes wanted before implementation)

### W1. The reconcile step is not gated on `not opaque?` — and its code placement decides whether it can be

`plan:351-378`, `coverage.ex:187-188`, `data_layer.ex:880-905`.

An opaque query (filter embeds a calc ref the normaliser can't see through)
reaches the backfill path: `covers?` → `{:miss, :solver_unsupported}` → (F3
gate) `remainder_plan` → `:none` → `source_read` → `maybe_backfill`.
`recordable?` is true for an opaque query without limit/offset/distinct/lock, so
`Backfill.upsert_records` **runs** (writing source rows into the cache —
harmless; they're correct, just uncoverable). Then `Coverage.record` is called
and skips on `normalised.opaque?` (`coverage.ex:188`).

The plan places reconcile "after `Backfill.upsert_records`, before
`Coverage.record`'s insert" — a *time* description that is ambiguous about *code
location*, and that ambiguity is load-bearing:

- If reconcile lives **inside `Coverage.record`** (after the
  `recordable?`/`not opaque?` gate, before the insert): it is automatically
  gated — but then `record` needs the **source-fetched PK set** threaded in,
  which is a second signature change on top of the `epoch0` parameter from F1,
  and the single lib caller (`data_layer.ex:904`) plus any test callers must
  supply both.
- If reconcile lives **in `maybe_backfill`** (after `upsert_records`, before
  calling `record`): it is *outside* record's opaque gate and will run a
  `Delegate.run_on_layer` of an opaque Q against the cache layer, which cannot
  evaluate the calc ref — a crash or silent `:unknown`, exactly on the path the
  C2/F3 work exists to protect.

Either is fixable; the plan must pick one and say so. The cleaner choice is
inside `record` (reconcile is meaningless when recording won't happen — there is
no "recorded filter" to reconcile against for an opaque query), which means
naming the PK-set threading as part of record's signature change.

### W2. The per-tenant epoch seeding mechanism is not implementable as described

`plan:224-229`. "TableOwner.init seeds each table's epoch space with
`System.unique_integer([:positive, :monotonic])`, and `Coverage.reset/1`
re-seeds." But epochs are keyed per resource+tenant
(`{:__mdl_meta__, :epoch, tenant_key}`), and `TableOwner.init` (`table_owner.ex`)
does not — and cannot — know the tenant set. So "seed at init" for an unbounded
tenant set is not a directly implementable instruction.

The *correctness property* F6 needs is sound and statable independently of the
mechanism: **after any restart or `reset/1`, a reader's stale snapshot must not
compare equal to the current epoch.** That is achieved by the combination of (a)
"absent ⇒ abort" (already specified) and (b) ensuring a post-restart epoch a
returning reader observes is never the value it snapshotted. The plan should
state the actual mechanism, e.g. one of:

- a table-level generation counter `{:__mdl_meta__, :generation}` seeded at init
  and folded into every tenant epoch value the reader compares (so a restart
  changes the generation and invalidates all stale snapshots); or
- lazy per-tenant seeding where `bump_epoch`'s `:ets.update_counter/4` default
  uses a generation drawn from the table-level seed, and "absent ⇒ abort" handles
  the never-bumped and post-restart cases (this needs no per-tenant work in
  init at all).

Pick one; as written an implementer will either seed a single tenant at init
(wrong) or block on the ambiguity.

---

## Suggestions

### S1. The fingerprint-widening `update_element` has a read-modify-write race on `loaded_fields`

`plan:125-142`. Two readers concurrently widening the same entry with disjoint
field sets each read the old `loaded_fields`, compute their own union, and
`update_element` — the second overwrites the first, losing one widening. The
epoch verify checks the *epoch*, not `loaded_fields`, so it does not catch this.

Severity is low and the consequence is **transient unnecessary misses, not
staleness**: physical rows are correct (`force_change_attributes` never strips
fields, so each backfill's fields persist regardless of the metadata race), and
a later reader re-widens. Given the epoch discipline already makes recording
best-effort under write load, this is probably acceptable — but the plan
presents widening as atomic ("union ... via `:ets.update_element`"); it should
either note the race or specify a CAS/serialised widening (e.g. fold it into
record's epoch-bracketed critical section, which already serialises on the
verify). A brief "concurrent widenings are a last-writer union on the metadata;
physical rows are unaffected; a later read re-widens" sentence would do.

### S2. Name the `Coverage.record` signature change and its blast radius

`plan:253-267`. F1 moves the epoch discipline into `record` (new `epoch0`
param); W1 above may add a source-PK-set param. `record` has exactly **one** lib
caller (`data_layer.ex:904`, confirmed by grep) so the production change is
contained, but `record` is `@spec`-public and likely called from existing unit
tests (e.g. `coverage_test`, the cap/LRU tests). The plan should note the
signature change explicitly so the implementer updates those callers and
doesn't discover them at compile time. If W1 is resolved by keeping reconcile
in `maybe_backfill`, the PK set stays out of `record`'s signature — another
reason to pick the reconcile placement deliberately (W1).

### S3. Evict-on-update cost for remote earlier layers deserves the same treatment as the reconcile cost

`plan:329-339`, decision 6. For local writes, evict-then-propagate is
acknowledged as "redundant churn." For a **remote** earlier layer (the
local-first strategies the orchestrator ADR contemplates), that churn is two
network round trips per local update (evict + re-upsert) instead of one. The
plan gives the reconcile cost the honest "strategy-specific, state it in code"
treatment (W-P4/F4 cost note); the evict-on-local-update cost should get the
same one-liner, since decision 6 makes the single-code-path trade-off
unconditionally and a future strategy author would otherwise re-derive it.

---

## Notes that need no plan change

- **BlockingLayer parks after delegating** (F12): verified the only useful
  semantics — `run_query` delegates, captures the pre-write result, then parks.
  Correct as specified.
- **`Debug`** (F13): confirmed `debug.ex:44,49,65` calls `needed_fields` and
  `probe.opaque?` itself, so Phase 1's widening and Phase 2's gate flow into
  `ash_multi_datalayer.inspect` with no edit. The plan's note is accurate.
- **`coverage_split/2 → /3`**: confirmed sole caller is `remainder_plan`
  (`data_layer.ex:771`); the arity change is contained.
- **Downstream test path** (F9): the corrected
  `../ash_remote_cache/example/todo_client/...` path is right; this repo's own
  `example/todo_client` lines `:52`/`:90` are unrelated tests.

## Summary

2 warnings, 3 suggestions. No criticals.

The plan is implementable modulo W1 (pick where reconcile lives — it must be
gated on non-opaque, which decides `record`'s signature) and W2 (state the
seeding mechanism). Both are spec-precision fixes inside the existing phases,
not redesigns. Everything the first two passes raised is either adopted with
sound reasoning or explicitly rejected with a correct justification (decision
3). The third-pass items are smaller than either prior pass because the
amendments did the heavy lifting.

---

**Last Updated**: 2026-07-05
