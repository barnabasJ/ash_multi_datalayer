# Review (pass 4): task coverage for `20260707-second-review-fixes/`

**Date**: 2026-07-07 (fourth pass)
**Subject**: re-review after the author absorbed pass-3a
(`…task-coverage-review-3.md`, F1–F7) and pass-3b (`…-pass3.md`, §A/§B), and
added a `final-gates.md` task plus an A0 retained-regression bullet.
**Method**: read every changed file; verified bidirectional index↔file integrity;
re-checked the new final-gates task and A0 additions for correctness.

---

## Verdict — sign-off; the tracker has converged

**The task set is complete, internally consistent, and ready to execute. No
actionable tracker defect remains.** All findings from all five review passes
(1, 2a, 2b, 3a, 3b) are resolved. I found no new coverage gap, no inaccuracy,
and no broken reference this pass.

The remaining control is **execution + the repro-first gate**, not more tracker
authoring. My recommendation in §B is that this be the final tracker-review
pass.

### Integrity check (new this pass)
Bidirectional scan of `00-index.md` ↔ task files: **all 45 referenced `.md`
targets resolve; no orphan task file; no broken link.** The closure rule
("nothing outside the tables and `deferred-follow-ups.md` is open; tracker not
closed until `final-gates.md` done") is now structurally enforceable.

---

## Prior findings — all closed

### Pass-3a (F1–F7)
- **F1** (final gates unowned): ✅ new **`final-gates.md`** + `FINAL` index row
  ("last to close") + closure-rule update. This was the last *structural* gap —
  it closes the loophole where every task could be DONE while the plan sat below
  its completion bar (demo exercise, docs sweep, changelog). Correctly framed as
  an aggregation gate (its "tests" are the joint suite run + the demo), not a
  repro-first task. Gate 2's "never restart/reconfigure shared Postgres or
  containers — report instead of fixing" guardrail is the right posture.
- **F2** (M4 missing `discard_local` read-error regression): ✅ dedicated
  retained-regression bullet added (`m4…:41-44`), owned by M4 or a named A0 test.
- **F3** (already-fixed 5-vs-6 count): ✅ index reconciled — enumerated list is
  unambiguous (`00-index:150-154`).
- **F4** (L13 item 4 repro vs confirmation): ✅ index clarifies it's a doc
  comment, "confirmation during the docs sweep, no test" (`00-index:152-154`).
- **F5** (P4 ambiguous `M6`): ✅ P4 now disambiguates inline — "the comment's
  'M6' means the **20260704 review's M6**, i.e. THIS task, not this tracker's
  M6" (`p4…:4-6`).
- **F6** (A0 ordering note): ✅ A0 now points to the index's recommended order
  (`a0…:29-31`).
- **F7** (L9 follow-up tracker): ✅ L9 names `deferred-follow-ups.md` as the
  canonical parked list (`l9…:28-30`).

### Pass-3b (§A, §B)
- **§A** (commit-fragility): ✅ recorded as the ⚠ note at `00-index:156-161`.
  The `lib/` working tree is still uncommitted — but that's the user's call
  (not a tracker defect), and the note now makes the latent risk visible to
  anyone executing the retained-regression items.
- **§B** (M5 shadow): ✅ M5 marked "subsumed by H3, closes with it; do not work
  independently" (`m5…:3-5`); index row annotated.

### Author-initiated improvements (not from any review finding)
- **A0 retained-regression bullet** (`a0…:37-42`): now explicitly requires
  regression tests for landed-but-untested work — #22 authority-order verifier,
  `default_can?` (#20), upsert arity guards (first-review B1). This closes the
  "landed but untested" loop I flagged as far back as pass 1 (#22). Good.
- **`final-gates.md`** gate 6 notes `CHANGELOG.md` is already modified in the
  working tree and must be reconciled with what actually lands — accurate (it's
  in `git status`).

---

## §A — one optional wording polish (non-blocking)

`00-index:150-151`: *"B1's #27 half and L12 items 3/4/5/8 — five from pass 2b
plus the separately-verified write_ref guard."*

The **enumerated list is correct** (5 items: B1#27, L12-3/4/5/8). The provenance
phrase reads as "5 + 1 = 6" but write_ref *is* L12-8 (one of the 5), so it's
really "pass 2b's 5 − L13-4 (doc-only) + L12-8 (write_ref) = 5." A cleaner
one-liner would be: *"five items needing a retained regression test: B1's #27
half and L12 items 3/4/5/8 (L13 item 4 is doc-only — confirmation, no test)."*
Purely cosmetic; the current text is not wrong, just slightly easy to
misread as six.

---

## §B — recommend this be the final tracker review

Five passes have now produced only polish since pass 2b. The tracker has:
- total coverage of all three source reviews (no orphans),
- accurate, source-verified citations on every task,
- a binding repro-first discipline + per-task suite gate,
- a binding canonical-tenant decision coordinating the tenant unit,
- a deferred-follow-ups file so "deferred ≠ forgotten,"
- a final-gates task so "all tasks done ≠ plan complete,"
- and the commit-fragility risk documented.

Continuing to review the tracker has hit diminishing returns. The honest next
step is to **execute** — starting with a checkpoint commit of the uncommitted
`lib/` tree (so the "fixed-in-tree" labels can't silently vanish), then B1/B2
(security) and the tenant unit, repro-first per A0/R0. Any remaining
misclassification will surface at execution time, when a "fails-on-unfixed"
repro unexpectedly passes — which is exactly the safety property the gate is
designed to provide.

---

## Summary

- Pass-3a (F1–F7): **7/7 resolved**.
- Pass-3b (§A, §B): **resolved**.
- New coverage gaps: **none**. Broken links/orphans: **none**.
- Inaccuracies: **none**.
- Author-initiated hardening: `final-gates.md` + A0 retained-regression bullet
  (both good).
- Remaining: 1 optional wording polish (§A); a meta-recommendation to stop
  reviewing and start executing (§B).

**Sign-off: ready to execute.**
