# Review: 20260707 second-review task coverage

**Date**: 2026-07-07
**Subject**: `docs/tasks/20260707-second-review-fixes/`
**Scope**: task-file quality and coverage against prior review findings for
`ash_multi_datalayer` and sibling `../ash_remote`.

This review treats `docs/tasks/20260706-review-findings-fix-handoff.md` as the
claimed completed first-plan work, then checks whether the 20260707 task set
covers the remaining findings and preserves the repro-first gates.

## Findings

### F1 - HIGH: A0/R0 can be marked done while skipping required retained regressions

- **Files**:
  `docs/tasks/20260707-second-review-fixes/a0-mdl-repro-harness.md:20-39`,
  `docs/tasks/20260707-second-review-fixes/r0-ash-remote-repro-harness.md:18-42`
- **Source**:
  `docs/plans/20260706-second-review-findings-fix-plan.md:593-595`,
  `docs/reviews/20260707-second-review-fix-plan-implementation-review.md:37-45`

Both harness tasks say to implement full plan phases A0/R0, but their done gates
narrow completion to "every open task in this directory." The plan explicitly
says that if a finding is already fixed by earlier work, its regression test must
still be kept or added. This matters because the review's central complaint was
that skipped repro gates let fixes look correct while defects remained.

The harness tasks should require all plan A0/R0 repros and retained regressions,
not only the currently open task files.

### F2 - HIGH: Several prior MDL findings are missing from the 20260707 task set

- **Missing review items**:
  `docs/reviews/20260704-implementation-review.md:207-230` (source-computed
  aggregate guard bypass on cold-cache, kill-switch, non-mergeable, and
  single-layer paths), `:255-275` (Spark verifier warnings do not block plain
  `mix compile`), `:277-291` (uncomputable calc guard misses
  `distinct`/`distinct_sort`), `:293-308` (`global? true` tenant invalidation),
  `:328-343` (Hex package cannot build/publish)
- **Current task coverage**:
  `docs/tasks/20260707-second-review-fixes/00-index.md:29-86`,
  partial overlap only in
  `docs/tasks/20260707-second-review-fixes/l2-aggregate-fold-notloaded.md` and
  `docs/tasks/20260707-second-review-fixes/b3-tenant-from-filter-dead-code.md`

The task set does not include dedicated tasks for these older findings. Some are
partially adjacent to later findings, but not covered with the original failure
scenarios or acceptance criteria.

The most concerning omissions are verifier posture and aggregate guard coverage:
they are correctness/security-adjacent and can still pass ordinary tests if only
the later NotLoaded fold task is fixed.

### F3 - HIGH: Original second-review #4 lost-kick recovery is not clearly task-covered

- **Source**:
  `docs/reviews/20260706-second-review-findings.md:71-80`
- **Current task coverage**:
  `docs/tasks/20260707-second-review-fixes/l5-sweeper-global-name-multinode.md:14-35`
- **Confusing source text**:
  `docs/reviews/20260707-second-review-fix-plan-implementation-review.md:37-43`

Original #4 is the missing MDL sweeper / lost-kick recovery problem. The current
task set has L5 for the new sweeper's global name and multi-node posture, but no
task that explicitly requires the original recovery semantics: pending entries
without jobs are discovered, same-PK tails are eventually kicked, and discarded
`Enqueue.flush` / `Oban.insert` failures are surfaced or recoverable.

The implementation review text also says "#4 (external-change)," but
external-change is #21/B4, not #4. That mislabel makes it easier for the actual
lost-kick recovery requirement to fall through the cracks again.

### F4 - HIGH: First-plan completion claims contradict the handoff's out-of-scope follow-ups

- **Files**:
  `docs/tasks/20260707-second-review-fixes/00-index.md:100-110`,
  `docs/tasks/20260706-review-findings-fix-handoff.md:59-67`
- **Source**:
  `docs/reviews/20260706-whole-repo-review.md:99-105`,
  `docs/reviews/20260706-whole-repo-review.md:145-150`

The 20260707 index says the committed history is the first fix plan and that
M-1...M-12 / R-1...R-11 are done. The first-plan handoff explicitly excluded
M-12's declared follow-ups and anything for M-7 beyond the A4 documentation task.

Those exclusions need either tasks, an explicit WONTFIX/deferred record, or a
more precise index statement. As written, a future implementer can reasonably
believe all M-7 and M-12 material is closed.

### F5 - MEDIUM: B1 omits part of the security surface it claims to cover

- **File**:
  `docs/tasks/20260707-second-review-fixes/b1-rpc-private-calc-aggregate-exfiltration.md:9-10`,
  `:39-46`
- **Source**:
  `docs/reviews/20260706-second-review-findings.md:350-356`,
  `docs/plans/20260706-second-review-findings-fix-plan.md:406-423`

B1 lists original findings #1 and #27, but the done criteria only require
private calculation/aggregate exfiltration tests. Original #27 is the
field-policy-denied `%Ash.ForbiddenField{}` / `%Ash.NotSelected{}` serialization
path that can 500 an RPC read. R0 mentions a harness test, but no implementation
task requires fixing and retaining that behavior.

B1 should include the field-policy-denied selection acceptance criteria, and it
should require coverage across both selection and serialization paths, including
create/update responses if those can return requested fields.

### F6 - MEDIUM: Tenant canonicalization instructions conflict on typed keys vs a single string partition

- **Files**:
  `docs/tasks/20260707-second-review-fixes/b3-tenant-from-filter-dead-code.md:40-48`,
  `docs/tasks/20260707-second-review-fixes/h5-localoutbox-nil-tenant-model.md:41-45`,
  `docs/tasks/20260707-second-review-fixes/00-index.md:90-93`
- **Source**:
  `docs/reviews/20260707-second-review-fix-plan-implementation-review.md:479-482`

B3 says to preserve the tenant value's type, while the index and implementation
review recommend one canonical function mapping tenant representations to a
single partition string. H5 also notes that outbox entries store stringified
tenants.

This ambiguity can split coverage and LocalOutbox fixes: one implementer might
preserve typed coverage keys while another continues to use stringified outbox
keys. The task set should choose one canonical representation and require every
path to use it.

### F7 - MEDIUM: Original second-review #22 has no explicit task or soundly-landed callout

- **Source**:
  `docs/reviews/20260706-second-review-findings.md:304-310`
- **Index**:
  `docs/tasks/20260707-second-review-fixes/00-index.md:81-110`

Original #22 requires a verifier tying ProvenCoverage write authority to the
read source. It is absent from the open task table and also absent from the
"What DID land soundly" list. If it landed, the index should say so. If it did
not, it needs a task with verifier tests.

### F8 - MEDIUM: `m11` can be read as converting malformed protocol responses to empty success

- **File**:
  `docs/tasks/20260707-second-review-fixes/m11-decoder-crashes-nil-single-object.md:27-37`
- **Source**:
  `docs/plans/20260706-second-review-findings-fix-plan.md:488-489`

The task suggests `nil -> []` for `data: null`, but the plan says malformed
successful responses with missing data should become typed protocol errors. The
task should distinguish valid no-row/get responses from malformed success shapes
so a protocol-corruption response is not silently normalized into an empty result.

### F9 - MEDIUM: `m9` still leaves an escape hatch for a partial-cleanup posture

- **File**:
  `docs/tasks/20260707-second-review-fixes/m9-discard-drop-chain-not-transactional.md:23-35`
- **Source**:
  `docs/plans/20260706-second-review-findings-fix-plan.md:603-606`

M9 says a documented partial-failure posture may satisfy the done criteria, but
the accepted W1 disposition already decided that drop-chain and rebase cleanup
need real co-commit Ecto transactions. Leaving the alternate path in the task
creates a way to mark the task done below the reviewed plan's fidelity bar.

### F10 - MEDIUM: AshRemote LOW findings are missing or only harness-mentioned

- **Missing source items**:
  `docs/reviews/20260706-second-review-findings.md:479-490`
- **Current partial coverage**:
  `docs/tasks/20260707-second-review-fixes/r0-ash-remote-repro-harness.md:20-31`,
  `docs/tasks/20260707-second-review-fixes/l10-doc-code-contradictions.md:1-31`

The current task set does not include implementation/documentation tasks for:
unauthenticated `GET /manifest.json` schema disclosure, join-time-snapshot
subscription revocation posture, per-subscriber DB refetch amplification on
`:unknown` filter evaluation, or the stale `connect_params` doc comment.

R0 mentions manifest access and revocation posture as tests, but the task set has
no owner for the actual fix/documentation work. L10 is MDL-only and does not
cover ash_remote realtime docs.

### F11 - LOW: L6 lists defects that its done criteria do not require

- **File**:
  `docs/tasks/20260707-second-review-fixes/l6-codegen-lows.md:13-36`
- **Source**:
  `docs/reviews/20260707-second-review-fix-plan-implementation-review.md:427-432`,
  `docs/plans/20260706-second-review-findings-fix-plan.md:449-453`

L6's defect list includes missing aggregate kinds in `@known_atoms` and
many-to-many/private aggregate handling, but its done criteria only require
identifier/path/FK/nullability/calc-arg coverage. An implementation could satisfy
the checklist while leaving two listed defects unresolved.

### F12 - LOW: Multiple task-level gates weaken or omit the suite requirement

- **Index requirement**:
  `docs/tasks/20260707-second-review-fixes/00-index.md:19-25`
- **Examples**:
  `docs/tasks/20260707-second-review-fixes/b5-validate-aggregate-overrides-regression.md:33-40`,
  `docs/tasks/20260707-second-review-fixes/l5-sweeper-global-name-multinode.md:30-35`,
  `docs/tasks/20260707-second-review-fixes/l10-doc-code-contradictions.md:27-31`

The index says every task requires the touched repo's full suite, with MDL using
`INTEGRATION=1`. Several MDL task files say only plain `mix test`, and L10 has no
suite gate. The per-task checklists should repeat the index gate so the final
task-level checklist cannot be interpreted as weaker.

### F13 - LOW: Remaining MDL LOW findings are not represented

- **Source**:
  `docs/reviews/20260706-second-review-findings.md:422-463`
- **Current index**:
  `docs/tasks/20260707-second-review-fixes/00-index.md:65-80`

The current LOW task table does not cover several review-listed MDL LOW items:
`Coverage.insert/2` `ArgumentError` rescue, dedupe `phash2` collision compare,
crash-safe pending/active ledger protocol, global ledger cap / epoch GC,
`Capability.collect/2` skipping `simple_expression`, divergence false positives,
explicit supervisor resource filtering, missing-remote update stale-check,
upsert stale-check bypass documentation, `:synced` pruning, and HostResolver
hot-reload invalidation.

Some may be intentional deferrals, but they need explicit tasks, WONTFIX entries,
or a deferred-follow-up list so they are not silently lost.

## Non-findings

- No broken relative markdown links were found in the task directory during this
  review.
- Every 20260707 implementation-review blocker/high/medium/low ID has a matching
  task file. The main gaps are incomplete acceptance criteria and findings from
  earlier reviews that are missing, ambiguous, or only harness-mentioned.
