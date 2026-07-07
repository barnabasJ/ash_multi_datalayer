# Review (pass 3): task coverage for `20260707-second-review-fixes/`

**Date**: 2026-07-07 (third pass)
**Subject**: re-review after the author absorbed pass-2a
(`20260707-second-review-fixes-task-coverage-review-2.md`, F1–F8) and pass-2b
(`…-pass2.md`, §A already-fixed items + §B `delete_local_pk`).
**Method**: read every changed file; re-verified every newly-cited `file:line`
and every "fixed-in-tree" claim against source.

---

## Verdict — ready to execute

**The task set is complete and the tracker-review cycle has converged.** All
findings from all three prior reviews (second-review #1–#27/A1–A5/B1–B3 + LOWs;
first-review M-1…M-12/R-1…R-11; 20260704 M2/M4/M5/M6/R1) now have a tracked
home, and the two independent review threads (2a + 2b) have both been fully
absorbed. I found **no open coverage gap and no inaccurate task** this pass.

This is a sign-off with two minor observations (§A, §B) — neither blocks
execution. The repro-first gate (A0/R0) is the remaining control, and it is now
correctly framed across every task.

---

## Prior findings — all closed

### Pass-2a (F1–F8) — verified resolved
- **F1** (P6 disable-sweeper loophole): ✅ P6 now requires repros that "fail
  against the **current working-tree code** for the actual recovery gaps — not
  merely with the sweeper disabled/removed" (`p6…:47-53`), with the
  disable-sweeper test explicitly demoted to "supplement, never the sole repro."
- **F2** (sweeper enqueue errors untested): ✅ dedicated repro bullet added
  (`p6…:58-62`).
- **F3** (B3 zero-row reads): ✅ "Zero-row reads" section + done-when bullet
  (`b3…:48-53, 73-75`).
- **F4** (rebase cleanup in M9): ✅ in scope (`m9…:23-27, 43-45`), with the W1
  re-litigation guard ("reopening that decision means re-litigating W1 with the
  user, not a checklist choice").
- **F5** (rowid-reuse owner): ✅ L12 item 8. Source-verified this pass:
  `write.ex:217` `write_ref = Ash.UUID.generate()`, threaded through
  `enqueue.ex:31`. The "fixed-in-tree" label is correct.
- **F6** (weak task-local gates): ✅ M5 (`:30`), L9 (`:29`), P5 (`:33-34`) all
  now carry the full touched-repo suite gate.
- **F7** (B1 plan-ref under-described): ✅ B1 now "R1 items 1–2"
  (`b1…:9-10`), with #1-regression retention explicit (`:69-70`).
- **F8** (refetch pre-deferred): ✅ `deferred-follow-ups.md:33-38` now a
  **conditional** deferral ("not pre-deferred; do not skip the L13 attempt"),
  mirrored by L13's "measured amplification" requirement.

### Pass-2b (§A, §B) — verified resolved
- **§A** (5 already-fixed-as-open): ✅ B1 #27 (`b1…:44-50, 65-68`), L12 items
  3/4/5 (`l12…:23-33`), L13 item 4 (`l13…:27-30`) all struck-through and
  re-labeled "fixed in tree — retain regression test." L12 item 8 added
  alongside. The index consolidates this into a global rule (`00-index:141-143`).
- **§B** (`delete_local_pk/3` raise in H3): ✅ H3 third bullet now covers it
  (`h3…:48-50`).

### Spot-checked citations — all accurate
`flush.ex:233` (B6), `proven_coverage.ex:471` (P3), `invalidation.ex:73` (P4),
`write.ex:217`+`enqueue.ex:31` (L12-8), `capability.ex:38,56` (L12-3),
`supervisor.ex:62,68` (L12-4), `flush.ex:199-203` (L12-5), `connection.ex:29,170`
(L13-4), `fields.ex:97-102` (B1/#27). No stale line numbers.

---

## A. Minor — "fixed in the uncommitted working tree" is commit-fragile

Five items are labeled fixed solely by virtue of the **uncommitted** working
tree: B1/#27, L12 items 3/4/5/8. The index rule (`00-index:141-143`) handles the
"repro unexpectedly fails → wrong label" case, but **not** the "working tree
discarded" case: a `git checkout` / branch switch silently reverts all five
fixes, and with no committed regression test yet, nothing catches the regression.

**Recommendation**: before executing the "retain regression test" items, commit
the current MDL + ash_remote `lib/` working tree (or at least the relevant
files: `fields.ex`, `capability.ex`, `supervisor.ex`, `flush.ex`,
`write.ex`/`enqueue.ex`) as a checkpoint. Then the fixed-in-tree labels are
durable and the regression tests guard against backslide rather than against
checkout. One line in the index's "Already-fixed-in-tree" note to this effect
would close the loop.

## B. Minor — M5 is now a pure shadow of H3

M5's body and done-when delegate entirely to H3 ("Resolved by implementing H3";
its own checklist is H3's mechanism + the A5-verify-3 assertion, which H3's
second bullet already owns). It's no longer independently actionable. Either
(a) mark M5 `CLOSED — subsumed by H3` with a one-line pointer, or (b) keep it as
a deliberate plan-fidelity breadcrumb (the plan tracked #13's atomicity
separately). Keeping it is harmless; just noting it will close automatically when
H3 closes and need not be worked independently.

---

## Final coverage check

- Second review: 34 HIGH/MED/letter → all tasked/verified-fixed; ~30 LOWs →
  L1–L13 + deferred. No orphans.
- First review: committed; M-7/M-12 explicitly parked in `deferred-follow-ups.md`.
- 20260704 review: P1–P5.
- Three tracker reviews (pass 1, 2a, 2b) all absorbed; no outstanding review
  finding remains unaddressed.

**The set is ready to execute.** The only residual risk is the uncommitted-tree
dependency in §A — recommend a checkpoint commit first. After that, the
repro-first gate is the sole control, and it is now correctly specified on every
task.

---

## Summary

- Pass-2a (F1–F8): **8/8 resolved**.
- Pass-2b (§A, §B): **resolved**.
- New coverage gaps: **none**.
- New inaccuracies: **none** (all cited lines verified).
- Remaining notes: 2 minor (§A commit-fragility, §B M5 shadow) — neither blocks.
