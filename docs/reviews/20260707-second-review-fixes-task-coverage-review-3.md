# Review: 20260707 second-review task coverage, pass 3

**Date**: 2026-07-07
**Subject**: updated `docs/tasks/20260707-second-review-fixes/`
**Prior task-set reviews**:
`20260707-second-review-fixes-task-coverage-review.md`,
`20260707-second-review-fixes-task-coverage-review-2.md`, and
`20260707-second-review-fixes-task-coverage-review-pass2.md`.

The latest task updates address the major pass-2 issues: P6 now requires current
working-tree repros and sweeper enqueue-error coverage, B3 now covers zero-row
attribute-tenant reads, M9 includes rebase cleanup, L12 owns the rowid/write_ref
regression, task-local suite gates were mostly normalized, and B1's #27 half is
called out as likely already fixed with retained-regression requirements.

The remaining findings are smaller tracker/closure issues. I did not find a new
orphan for the 20260707 implementation-review findings.

## Findings

### F1 - MEDIUM: Plan final gates are not owned by any task

- **Task index**: `docs/tasks/20260707-second-review-fixes/00-index.md:122-125`
- **Current discipline**: `docs/tasks/20260707-second-review-fixes/00-index.md:29-35`
- **Source plan gates**: `docs/plans/20260706-second-review-findings-fix-plan.md:569-580`
- **Prior handoff gate**: `docs/tasks/20260706-review-findings-fix-handoff.md:69-83`

The index says deliberately parked items live in `deferred-follow-ups.md` and
"Nothing outside these tables and that file is open." The task discipline covers
per-task repros and full suites, but no task owns the source plan's final gates:
the offline-first example exercise, semantic docs sweep, changelog/decision-log
updates where applicable, and the cross-repo release/demo closure checks.

This means all task rows can be marked done while the cited plan is still below
its completion bar. Add a final-gate task, or extend A0/R0 with explicit final
gate ownership, so the execution tracker cannot close before the demo/docs gates
are run or explicitly reported blocked.

### F2 - LOW: M4 can close without the explicit `discard_local/1` read-error regression

- **Task**: `docs/tasks/20260707-second-review-fixes/m4-discard-local-chain-destroy.md:35-41`
- **Source finding**: `docs/reviews/20260706-second-review-findings.md:266-272`
- **Plan refs**: `docs/plans/20260706-second-review-findings-fix-plan.md:104-105`,
  `docs/plans/20260706-second-review-findings-fix-plan.md:298-299`

Original #18 requires `discard_local`, `refresh`, and `hydrate` to return
structured errors on target read failures instead of crashing. M4 cites #18, but
its done checklist covers concurrent-chain destruction, head guards, and the
remote-gone tenant branch only. It does not require the `Target.read_pk ->
{:error, _}` regression for `discard_local/1`.

Add a retained regression bullet to M4, or point explicitly to the A0 harness as
the owning test before M4 can close.

### F3 - LOW: Index already-fixed count conflicts with its item list

- **Index count**: `docs/tasks/20260707-second-review-fixes/00-index.md:15-18`
- **Index list**: `docs/tasks/20260707-second-review-fixes/00-index.md:141-143`

The index says pass 2b flagged 5 already-fixed-in-tree items, but the later list
names 6 if B1's #27 half is counted: B1 #27, L12 items 3, 4, 5, and 8, plus L13
item 4. Reconcile the count or the list so future implementers do not wonder
which retained regression is accidental.

### F4 - LOW: L13 item 4 is listed as requiring a retained repro, but the task only requires confirmation

- **Index**: `docs/tasks/20260707-second-review-fixes/00-index.md:141-143`
- **Task**: `docs/tasks/20260707-second-review-fixes/l13-ash-remote-server-realtime-lows.md:27-41`

The index says L13 item 4 is an already-fixed-in-tree item that needs a retained
regression repro. L13 itself says remaining work is none beyond confirming during
the docs sweep, and its done checklist only asks for doc-comment consistency
confirmation.

Either remove L13 item 4 from the retained-regression list, or add a concrete
retained regression/documentation test requirement to L13.

### F5 - LOW: P4 uses an ambiguous `M6` label that now points at the wrong current task

- **Task**: `docs/tasks/20260707-second-review-fixes/p4-global-tenant-invalidation.md:3-8`
- **Current M6 row**: `docs/tasks/20260707-second-review-fixes/00-index.md:80`

P4 says `invalidation.ex:72-73` defers the cross-partition sweep as "M6, still
open." In this current tracker, M6 is the destroy-flush already-gone parking
task, not the older 20260704 review M6 global-tenant finding.

Qualify this as "20260704 review M6" or avoid the unqualified `M6` label.

### F6 - LOW: A0's order note omits the current B4-B7 step

- **A0 task**: `docs/tasks/20260707-second-review-fixes/a0-mdl-repro-harness.md:27-30`
- **Index order**: `docs/tasks/20260707-second-review-fixes/00-index.md:127-135`

A0 says the review order puts the harness at step 4 after B1/B2 and the tenant
unit. The current index also places B4, B5, B6, and B7 before A0/R0. Align A0's
ordering note with the index, or simply point to the index's recommended order.

### F7 - LOW: L9 follow-up tracking should point to the canonical deferred file

- **Task**: `docs/tasks/20260707-second-review-fixes/l9-destroy-notification-drop-docs.md:21-29`
- **Index closure rule**: `docs/tasks/20260707-second-review-fixes/00-index.md:122-125`

L9 allows an explicit follow-up if LifecycleGuard coverage needs protocol
support, but it does not name the canonical tracker. The index says deliberately
parked items live in `deferred-follow-ups.md` and nothing outside the task tables
and that file is open.

Link L9's follow-up path to `deferred-follow-ups.md`, or state the alternate
tracker explicitly.

## Non-findings

- Pass-2 findings F1-F8 are substantively addressed in the updated task files.
- I did not find a new missing task for the 20260707 implementation-review IDs.
- The broad prior-review coverage claim is now mostly defensible, subject to F1's
  final-gate ownership gap.
