# Review: 20260707 second-review task coverage, pass 4

**Date**: 2026-07-07
**Subject**: updated `docs/tasks/20260707-second-review-fixes/`
**Prior task-set review**:
`docs/reviews/20260707-second-review-fixes-task-coverage-review-3.md`

The latest updates address the substantive pass-3 findings: the tracker now has
a `FINAL` task for plan closure gates, M4 owns the `discard_local/1` read-error
regression, P4 disambiguates the old M6 label, A0's order note points back to
the index, and L9 points follow-ups to `deferred-follow-ups.md`.

I found no new behavioral coverage gap for the reviewed defects. The remaining
findings are low-severity tracker wording issues.

## Findings

### F1 - LOW: Already-fixed retained-regression wording is still inconsistent

- **Index summary**: `docs/tasks/20260707-second-review-fixes/00-index.md:15-18`
- **Index retained-regression note**: `docs/tasks/20260707-second-review-fixes/00-index.md:150-154`
- **Task**: `docs/tasks/20260707-second-review-fixes/l13-ash-remote-server-realtime-lows.md:27-40`

The index summary says the already-fixed-in-tree items are re-labeled in
B1/L12/L13 with retained-regression requirements. Later, the index correctly says
L13 item 4 is a doc-comment fix that needs docs-sweep confirmation, not a test.
L13 itself also requires only doc-comment consistency confirmation.

This leaves the tracker internally inconsistent about whether L13 item 4 needs a
retained regression. Suggested wording: "B1 plus L12 items 3/4/5 require retained
regressions from pass 2b; L12-8 was separately verified and also needs a retained
regression; L13 item 4 is docs confirmation only."

### F2 - LOW: FINAL claims the first-plan handoff docs gate but omits some named handoff items

- **FINAL task**: `docs/tasks/20260707-second-review-fixes/final-gates.md:7-9`,
  `:19`, `:34-40`
- **First-plan handoff**: `docs/tasks/20260706-review-findings-fix-handoff.md:79-83`

`final-gates.md` says it owns the plan final gates plus the first-plan handoff
final gate. Its docs sweep mentions the second-review semantic docs, but it does
not name several first-plan handoff docs items: write-through spec promoted to
moduledoc, upsert collision note, realtime field stripping, and both repos'
CHANGELOG/DECISIONS sweep.

Either add those named first-plan handoff docs items to FINAL's gate list, or
narrow the claim so FINAL does not appear to cover the handoff docs gate.

## Non-findings

- Pass-3 F1-F7 are substantively addressed.
- I found no missing task for the 20260707 implementation-review IDs.
- I found no remaining unowned prior-review defect beyond the deliberately
  deferred items and the two tracker wording issues above.
