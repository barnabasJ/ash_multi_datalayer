# Review: 20260707 second-review task coverage, pass 2

**Date**: 2026-07-07
**Subject**: updated `docs/tasks/20260707-second-review-fixes/`
**Prior task-set review**:
`docs/reviews/20260707-second-review-fixes-task-coverage-review.md`

The updated task set closes most findings from the prior coverage review: it adds
P1-P6, L12, L13, a deferred-follow-ups file, a binding tenant-key decision, and
stronger acceptance criteria in several task files. The findings below are the
remaining actionable gaps I found in the updated task set.

## Findings

### F1 - HIGH: P6 still allows a non-repro-first lost-kick test

- **File**: `docs/tasks/20260707-second-review-fixes/p6-lost-kick-recovery.md:47-54`
- **Related requirement**: `docs/tasks/20260707-second-review-fixes/00-index.md:23-30`
- **Source finding**: `docs/reviews/20260706-second-review-findings.md:71-80`

P6's first done item says the no-job pending-entry test should fail "with the
sweeper disabled/removed." That does not prove the updated current code fails for
the reviewed reason. The index-level discipline requires every task's new test to
fail on the unfixed code as it stands, then pass after the fix.

This matters because P6 is specifically about a sweeper that now exists but is
untested. A test that only fails after disabling/removing the sweeper can pass on
an implementation that still drops `Enqueue.flush` errors, misses tenant-scoped
entries, or fails to enqueue real stranded heads.

The P6 done criteria should require lost-kick and enqueue-error repros that fail
against the current unfixed implementation for the actual recovery gap.

### F2 - MEDIUM: P6 names sweeper enqueue errors but does not require testing them

- **File**: `docs/tasks/20260707-second-review-fixes/p6-lost-kick-recovery.md:39-42`,
  `:47-54`
- **Source**: `docs/plans/20260706-second-review-findings-fix-plan.md:236-238`

The task notes that the sweeper itself discards `Enqueue.flush` errors in its
`Enum.each`, but the done criteria only require a write-path enqueue-failure
test. Plan A4 item 3 requires enqueue/Oban errors to be surfaced or made
deterministically recoverable. That applies to the recovery worker too: if the
sweeper drops its own enqueue error, the stranded entry can remain stranded with
no signal.

Add an acceptance item for sweeper-tick enqueue failures: either they are surfaced
through telemetry/logging and retried deterministically, or they are otherwise
proven recoverable.

### F3 - MEDIUM: B3 can still miss zero-row attribute-tenant reads

- **File**: `docs/tasks/20260707-second-review-fixes/b3-tenant-from-filter-dead-code.md:40-66`
- **Source**: `docs/reviews/20260707-second-review-fix-plan-implementation-review.md:129-133`

B3 permits deriving the tenant from returned rows, but it does not require a
zero-result filtered-read repro. That leaves a hole in the exact stale/missing
cache-hit class: an attribute-tenant read for `org_id == "acme"` can return no
rows, record coverage in the wrong partition, and then miss a later create for
`"acme"` if the tenant could only be extracted from rows.

The task should require either structural extraction from the filter AST for
empty results or conservative refusal to record tenant-scoped coverage when the
tenant cannot be proven. Add a repro for empty filtered read, later write/create,
then re-read.

### F4 - MEDIUM: Rebase cleanup is still not covered by the co-commit transaction task

- **File**: `docs/tasks/20260707-second-review-fixes/m9-discard-drop-chain-not-transactional.md:23-37`
- **Source**: `docs/plans/20260706-second-review-findings-fix-plan.md:289-293`,
  `:306-308`, `:603-606`; `docs/reviews/20260706-second-review-findings.md:416-421`

M9 now correctly removes the partial-cleanup escape hatch for create-discard and
`drop_chain`, but it still does not cover the accepted W1 requirement for rebase
cleanup. The plan explicitly folded the rebase-transaction LOW into A5 item 8 and
requires the same AshSqlite-safe real co-commit transaction or an explicitly
documented partial-failure posture.

Add rebase cleanup to M9, or create a dedicated task with a SQLite-backed test
that proves the chosen transaction/posture.

### F5 - LOW: SQLite rowid / Oban uniqueness regression has no task owner

- **File**: `docs/tasks/20260707-second-review-fixes/l12-mdl-misc-lows.md:13-47`
- **Source**: `docs/reviews/20260706-second-review-findings.md:449-451`,
  `docs/plans/20260706-second-review-findings-fix-plan.md:239-241`, `:542-545`

The plan requires a stable write reference, or equivalent protection, so SQLite
rowid reuse after discarding the max-seq entry cannot inherit stale Oban
uniqueness/backoff for a different outbox entry. L12 claims the relevant LOW
disposition items 1-3, but it does not include this item; P6 also does not cover
it.

Add this to L12 or record an explicit deferral with the reason and required
regression test.

### F6 - LOW: Some task-local suite gates remain weaker than the index gate

- **Index**: `docs/tasks/20260707-second-review-fixes/00-index.md:23-29`
- **Files**:
  `docs/tasks/20260707-second-review-fixes/m5-refresh-delete-reconciliation-not-atomic.md:21-30`,
  `docs/tasks/20260707-second-review-fixes/l9-destroy-notification-drop-docs.md:25-29`,
  `docs/tasks/20260707-second-review-fixes/p5-hex-package.md:28-33`

The index says every task requires the touched repo's full suite, with MDL using
`INTEGRATION=1 mix test` and ash_remote using `mix test`. A few task-local done
criteria are still weaker or omit the gate: M5 has no explicit full-suite item,
L9 only mentions doc-adjacent tests, and P5 says plain MDL `mix test`.

The index is binding, but task-local checklists are what implementers close. Add
the full touched-repo suite gate to these files.

### F7 - LOW: B1 metadata still under-describes the task's plan scope

- **File**: `docs/tasks/20260707-second-review-fixes/b1-rpc-private-calc-aggregate-exfiltration.md:7-10`,
  `:34-42`, `:54-62`
- **Source**: `docs/plans/20260706-second-review-findings-fix-plan.md:406-423`

B1 now correctly includes the #27 field-policy serialization crash in the task
body and done criteria, but its metadata still says the plan ref is only R1 item
1. The #27 half is R1 item 2. That mismatch is small, but these task files are
being used as implementation checklists; incomplete metadata is how coverage gets
lost during later passes.

Update the plan ref to R1 items 1-2. Also ensure the private-attribute #1
retained regression is explicitly owned by R0 or B1 before either is marked done.

### F8 - LOW: Refetch coalescing is pre-deferred without the plan's benchmark condition

- **Files**: `docs/tasks/20260707-second-review-fixes/deferred-follow-ups.md:28-34`,
  `docs/tasks/20260707-second-review-fixes/l13-ash-remote-server-realtime-lows.md:23-37`
- **Source**: `docs/plans/20260706-second-review-findings-fix-plan.md:517-519`,
  `:564-565`

L13 correctly requires either a simple shared per-resource/per-PK refetch cache
or a deferred follow-up recorded with measured amplification. The deferred file,
however, already parks a "per-subscriber refetch coalescing component" without
the benchmark condition. That creates an escape hatch where the performance issue
can be treated as deferred before L13 proves the simple fix is insufficient.

Make the deferred item conditional on L13's measurement, or move the benchmark
requirement into the deferred entry itself.

## Non-findings

- The prior review's major coverage gaps are mostly addressed: P1-P5 cover the
  older MDL findings, P6 covers original #4, L12/L13 cover the broad LOW batches,
  and the index now records explicit first-plan exclusions.
- No new missing task file was found for the 20260707 implementation-review IDs.
