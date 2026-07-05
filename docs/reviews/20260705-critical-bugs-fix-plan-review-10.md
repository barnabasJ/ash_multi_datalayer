# Plan Review (pass 8) — the seven-amendment critical-bugs-fix-plan.md

**Date:** 2026-07-05
**Scope:** the amended `docs/plans/critical-bugs-fix-plan.md` (the version whose
disposition tables cover passes 1–7), reviewed against all seven prior passes
and the current `lib/` source.
**Method:** verified the pass-6/7 amendments (epoch `{counter, incarnation}`
pair, `ensure_table` in the snapshot, non-seeding check-time lookups,
non-fatal/rescued `bump_epoch`, `touch` seam, `¬C` threading) against source —
including the two `run_query` branches pass-6 F2 names and `TestSupport`'s
actual surface — and re-derived the epoch-pair comparison and the snapshot's
two-step seed-or-read interleavings.

**Verdict:** the plan is correct and ready for Phase 0. The epoch pair resolves
pass-6 F1 exactly (incarnation makes cross-restart counter-arithmetic collision
impossible); `ensure_table` in the snapshot resolves pass-6 F2 (confirmed: the
`:calc_sort_source_only` and `:not_cacheable` branches at `data_layer.ex:516-531`
reach `maybe_backfill` without `covers?`, so without it those recordable query
shapes never cache from cold start); and the non-fatal `bump_epoch` / `touch`
seam / `¬C` threading adoptions are all sound. Two precision items remain, both
non-blocking — one wording fix, one assumption to state explicitly.

---

## Verified sound (pass-6/7 amendments, checked against source)

- **Epoch as `{counter, incarnation}`, compared as a pair.** Resolves pass-6 F1.
  Within an incarnation, `bump_epoch`'s `update_counter` on element 2 strictly
  moves the counter ⇒ pair mismatch on any write (the C3 guarantee). Across a
  TableOwner supervisor restart or `Coverage.reset/1` (`delete_all_objects`),
  the incarnation is a fresh raw `System.unique_integer([:positive])` output —
  unique for the VM's lifetime, so no stale `{c, old_inc}` can ever compare equal
  to a fresh `{c', new_inc}` regardless of counter arithmetic. A node restart
  wipes the ETS table *and* the reader processes holding snapshots, so
  cross-VM `unique_integer` recurrence is moot. Object shape
  `{key, counter, incarnation}` (3-tuple, key = `{:__mdl_meta__, :epoch,
  tenant_key}`) is still structurally invisible to `entries/2`/`size/2`'s
  `{{tenant, :_}, …}` patterns.
- **`ensure_table` in `Coverage.epoch/2` closes the cold-start side door**
  (pass-6 F2). Confirmed against source: `run_query`'s
  `:calc_sort_source_only` branch (`data_layer.ex:516-520`) and the
  `:not_cacheable` non-mergeable branch (`:528-531`) both route to
  `source_read` → `maybe_backfill` without passing through `covers?` (which is
  where `ensure_table` previously ran). Without the snapshot ensuring the table,
  the first such read on a resource finds no table, the (correct) rescue aborts
  caching, and the shape never backfills until an unrelated read creates the
  table. Abort caching only on `ensure_table`'s `{:error, :unavailable}` (the
  existing degraded mode) is the right line.
- **Check-time reads are plain non-seeding `:ets.lookup`** (pass-6 F3). With
  the pair compare this is cosmetic for mismatch, but it makes the
  "check-time absence ⇒ abort" clause live text (a restarted table yields a
  fresh seed → mismatch; a dying table yields `[]`/raise → absence/rescue →
  abort). Consistent.
- **Non-fatal `bump_epoch`** (pass-7 F1) — rescue, treat as moved/unavailable,
  continue best-effort with drops + eviction, never fail the committed write.
  See S2 for the one assumption this relies on.
- **`touch` seam** (pass-7 F3) — `Coverage.touch/3` as `@doc false` public +
  `TestSupport.touch_entry!/3` is implementable (confirmed `TestSupport`
  currently exposes only `reset!/1` at `test_support.ex:22-28`, so the
  pass-7-F3 objection to the prior "route through TestSupport" wording was
  correct — there was no seam). Deliberately revisiting review-1 S-P3 is the
  right call: a `@doc false` function fronted by the existing test-support
  module is better than a probabilistic concurrency test for a one-line fix.
- **`¬C` threaded as `complement:` opt into `maybe_backfill`** (pass-5 W1) —
  `nil` on the source-miss path (full-Q scan), the complement filter on the
  remainder path. Verified the threaded value is always `{:ok, filter}` on the
  remainder path: `:empty` would mean `C` is universal ⇒ a full hit, never a
  remainder read; `:universe` would mean `C` is empty ⇒ `coverage_split`
  returned `:none` ⇒ `remainder_plan` returned `:none`. So the plan's
  "¬C_filter" shorthand is accurate where it's used.
- **Check-insert-verify, reconcile-in-`maybe_backfill`, evict-before-image-PK,
  `forget!` NotLoaded probe, double-normalisation fix** — all re-confirmed sound
  (no change since pass 5's verification of the evaluator path).

---

## Findings

### S1. The snapshot's "atomic shape yielding the pair" is two-step and non-atomic — say so

`plan:262-264`. The plan specifies the snapshot as "`:ets.insert_new` with
`{key, 0, System.unique_integer([:positive])}` followed by a lookup — any
atomic shape yielding the pair." The concrete shape offered (`insert_new` then
`lookup`) is **two operations and non-atomic**, contradicting the "any atomic
shape" parenthetical. No single ETS op both inserts-if-absent *and* returns the
two-element pair (`update_counter` returns only the counter element;
`lookup_element` raises on absent and doesn't seed) — so the two-step is
genuinely unavoidable, not a choice.

This is sound (I re-derived it): a `bump_epoch` landing between the `insert_new`
and the `lookup` means the snapshot captures a post-bump pair, but the source
fetch runs *after* the snapshot and therefore *after* that bump's committed
authoritative write — so the fetched rows are fresh and recording is correct;
any *further* write between snapshot and check still mismatches and aborts. But
the implementer reading "atomic" will either chase a non-existent single-op
primitive or worry about the gap the word papere over. One sentence — "this is a
two-step seed-then-read, not atomic; it is sound because the source fetch follows
the snapshot, so a bump observed mid-snapshot is a committed write the fetch
already sees" — turns a wording bug into a documented invariant.

### S2. State the assumption the non-fatal `bump_epoch` relies on: bump and drops share the table

`plan:278-284`. The non-fatal bump posture (rescue ⇒ treat as moved ⇒ continue
with best-effort Drops + eviction) is sound *because* `bump_epoch` and
`Coverage.entries`/`drop` operate on the **same ETS table** — so a bump failure
(table dying/absent) coincides with the drops returning `[]`/`:ok` (their own
rescues), meaning no entries are dropped under an unmoved epoch. The one
arrangement that would reopen C3 — bump fails, epoch stays put, but drops
*succeed* and remove entries an in-flight reader then re-records over — is
unreachable precisely because bump and drops fail together on table death. If
the epoch ever moved to a different table than the entries (e.g. a future
`:persistent_term`-backed incarnation), this coincidence breaks and the
bump-failure path needs the write to abort recording explicitly. Worth one line
in the code comment so a future refactor doesn't silently split the two tables
and reopen the window the bump exists to guard.

---

## Notes (no plan change needed)

- The `epoch/2` return contract (`{:ok, {counter, incarnation}}` vs an abort
  sentinel when `ensure_table` fails) isn't spelled out, but is unambiguous from
  context; the implementer will infer it.
- Pass 5's review-trail-accuracy note (the "p3-F1"/"p3-F3" labels living only in
  pass 4's adjudication) is now resolved by the label note at `plan:668-670` —
  the audit trail no longer dead-ends at review-3's rewritten file.
- Pass 7 F2's race-test assertion ordering (no-entry check before any healing
  read) is correctly placed in Phase 0.3 — the most easily-misread acceptance
  gate, now ordered right.

## Summary

0 critical, 0 warnings, 2 suggestions. The seven amendments landed cleanly: the
epoch pair is the exact closure of the restart-collision window, `ensure_table`
plugs the cold-start side door, and the non-fatal bump / touch seam / `¬C`
threading are all implementable as specified. S1 is a wording fix (don't call a
two-step "atomic"); S2 is one sentence documenting a load-bearing assumption.
Nothing here blocks Phase 0.

---

**Last Updated**: 2026-07-05
