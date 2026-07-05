# Plan Review (pass 8) — the thrice-amended critical-bugs-fix-plan.md

**Date:** 2026-07-05 **Scope:** the third amendment of
`docs/plans/critical-bugs-fix-plan.md` (the version dispositioning passes 5–7:
p5-W1/S1/S2, p6-F1–F5, p7-F1–F3), reviewed against all seven prior passes and
the source. **Method:** each new disposition row was checked against the
originating finding and the implementing plan text; the changed Phase 3
mechanism (pair epoch via `insert_new` + lookup, non-seeding checks, non-fatal
bumps, `ensure_table`-first snapshot) and the Phase 4.2 complement threading
were re-derived interleaving by interleaving, as in passes 2, 4, and 6.

**Verdict:** the third amendment is faithful — all eleven pass-5/6/7 rows are
correctly adopted, and the pair-epoch mechanism as now specified is **sound**:
the incarnation component closes pass-6 F1's arithmetic collision exactly
(within an incarnation any bump moves the counter; across restart/reset the
incarnation is a raw `unique_integer` output that cannot recur in the VM's
lifetime), `ensure_table`-first closes the cold-start side door, non-seeding
checks make the absence clause meaningful, and the non-fatal bump contract is
correctly reasoned ("a table restart already erased the coverage the bump was
protecting"). One inherited defect: the plan adopted pass-5 W1's remedy _and its
incorrect justification_ — the claim that the entry set is stable across the
epoch-guarded window is false (F1 below), and leaving it in the plan invites a
future "optimisation" that silently erodes the cache. The rest is precision.

---

## Verified: third-amendment adoptions re-derived

- **p6-F1 — pair epoch `{counter, incarnation}`.** Correctly specified end to
  end: the object shape, pair comparison, and the reasoning. Bonus check: with
  the counter at element 2 of `{key, counter, incarnation}`, a plain integer
  `Incr` to `:ets.update_counter/4` already targets element 2, so the bump needs
  no explicit position tuple — the "identical default tuple shape" clause
  (p5-S2) is the only contract the implementer must hold.
- **p6-F2 — `ensure_table` at the snapshot.** Adopted with the right abort
  condition (only `{:error, :unavailable}` — the existing degraded mode) and the
  right paths named (calc-sort-source-only, non-mergeable computed).
- **p6-F3 — non-seeding check-time lookups.** Adopted; "absence _or_ pair
  mismatch ⇒ abort" is now meaningful text rather than dead text.
- **p7-F1 — non-fatal `bump_epoch`.** Adopted with the correct conservatism
  argument. Re-derived the compound failure (table dying mid-`on_write`): bump
  rescues → drops rescue to no-ops → eviction still runs → reader-side snapshots
  against the recreated table get a fresh incarnation, so no stale pair can
  compare equal. No gap.
- **p7-F2 — race-test assertion ordering.** Adopted precisely (no-entry
  assertion after the raced reader resumes, before any healing read).
- **p7-F3 — `touch` seam.** Adopted as a deliberate, recorded reversal of
  review-1 S-P3 (`@doc false Coverage.touch/3` + `TestSupport.touch_entry!/3`).
  The stated rationale — a probabilistic concurrency test for a one-line race
  fix is worse than one `@doc false` function behind the sanctioned test-support
  module — is right; pass 7's observation that `TestSupport` exposes only
  `reset!/1` today made the previous instruction genuinely unimplementable.
- **p5-W1 — complement threading.** The remedy (explicit `complement:` option
  from `remainder_read`, `nil` ⇒ full-Q scan) is the correct choice and the
  load-bearing warning ("scanning full Q deletes every covered row") is
  accurately preserved. The _justification for the rejected alternative_ is
  wrong — F1 below.
- **p5-S1/S2** — cost acknowledgment + read-mostly fallback; identical default
  shape: both adopted where the table says.
- **p6-F4/F5** — probe passed into `record`; label note: adopted (F4 creates one
  stale sentence — F3 below).

---

## F1 (should fix, Phase 4.2): "the entry set is stable across the guarded window" is false — the rejected recompute is not epoch-safe, and the plan now says it is

The complement-threading bullet closes with: "recomputation happens to be safe
under the epoch guard (the entry set is stable across the guarded window), but
threading keeps the plan's no-recomputed-coverage-state discipline." The
parenthetical — inherited verbatim from pass-5 W1's "(it _works_ — the epoch
guard guarantees the entry set is stable...)" — is incorrect. The epoch moves
**only on invalidation** (`on_write`/`drop_all`). At least four entry-set
mutations happen with no bump:

1. concurrent readers' `Coverage.record` inserts (new entries, new regions);
2. LRU cap eviction — `enforce_cap` drops the oldest entry on the way to an
   insert (`coverage.ex:220-241`), no bump;
3. Phase 1's fingerprint widenings (`update_element` on `loaded_fields`);
4. another reader's own check-insert-**verify** drop.

So a mid-window recompute of `coverage_split` can return a _different_ `C` than
the one the source fetch was planned against. The dangerous direction: an entry
dropped by (2) or (4) makes `¬C′ ⊃ ¬C`, the reconcile scans a region the source
**never fetched**, and every cached row there — fresh, legitimate, merely
no-longer-covered — is deleted as "∉ source-fetched set". That is degradation
(the rows were already uncovered when deleted, so no staleness), but it is
silent cache erosion under concurrency, and it flows from a sentence asserting
the opposite invariant.

The deeper point the plan should state instead: **"∉ source-fetched set" is only
meaningful over exactly the region the source actually fetched.** The reconcile
scan region and the source fetch region must be the _same object_, which is
precisely why ¬C is threaded from `remainder_read` rather than derived anywhere
else, later, from mutable state. Threading is _required for the reconcile's
semantics_, not a discipline nicety. Replace the parenthetical accordingly —
otherwise a future reader "simplifies" to a recompute, citing the plan's own
(false) safety claim, and the sentence also contradicts the mid-reconcile
tolerated-degradation accounting two bullets below (which only budgets for
_epoch-visible_ interference).

## Precision items

- **F2 — "seed-or-read atomically" overstates; and the reset-mid-snapshot corner
  is unspecified.** `insert_new` is atomic (no torn or duplicate seeds) and the
  object `lookup` is atomic, but the two-step sequence is not one atomic unit —
  which is fine, and worth saying _why_ it's fine: a bump landing between the
  two steps precedes the layer fetch, so the snapshot legitimately absorbs it.
  The one corner that isn't benign-by-argument: a `reset/1` or table death
  between `insert_new` and the `lookup` leaves the snapshot with **absence** —
  currently unspecified. One clause: absence at snapshot _after_ the seed
  attempt ⇒ abort caching (consistent with the rescue posture; retrying once is
  also fine, just say which).
- **F3 — Phase 3.3's signature note is stale after the p6-F4 adoption.** 3.3
  still says "`record/3` becomes `record/4` taking `epoch0`", while Phase 4.2
  now passes the pre-normalised probe into `record` as well. Update the note
  (`record/5`, or `epoch0` + probe in an opts keyword — pick one) and its
  blast-radius sentence, so the two sections describe the same function.
- **F4 — review-trail nit, for the archaeology only.** The label note says
  "p3-F1"/"p3-F3" _existed only in pass 4's adjudication section_. Strictly:
  they existed in review-3's **original published version** (a
  laundering-inside-C critical and the bare-PK `forget!` warning), which a later
  session rewrote in place into the current W1/W2/S1–S3 pass; pass 4 quoted and
  adjudicated the originals before they vanished. The note's practical
  conclusion (pass 4 is the surviving source) is right; if the trail is meant to
  be forensic, say "originally raised in review-3's first version, since
  overwritten; surviving text in pass 4" — one clause.

---

## Summary

1 should-fix (F1 — delete the false "entry set is stable" justification; the
threaded complement is _required_ by the reconcile's semantics, not discipline),
3 precision items (snapshot atomicity wording + reset corner; stale `record`
signature note; trail wording). All eleven pass-5/6/7 dispositions are faithful;
the pair-epoch mechanism survives full interleaving re-derivation, including the
compound table-death cases; no prior finding is reopened. With F1's sentence
corrected, this pass finds nothing standing between the plan and Phase 0.

---

**Last Updated:** 2026-07-05
