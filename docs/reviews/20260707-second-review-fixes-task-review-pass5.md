# Review: `20260707-second-review-fixes/` task files, pass 5

**Date**: 2026-07-07
**Subject**: current task set in
[`docs/tasks/20260707-second-review-fixes/`](../tasks/20260707-second-review-fixes/)
after the prior coverage, technical, and spec review fixes.
**Scope**: task-spec consistency, executability, tracker hygiene, and targeted
source-reference checks in `ash_multi_datalayer` and sibling `../ash_remote`.

## Findings

### Medium - Index fail-first exemptions omit retained regressions required by A0/R0

- **Task refs**: `00-index.md:55-61`, `00-index.md:182-186`,
  `a0-mdl-repro-harness.md:35-45`, `r0-ash-remote-repro-harness.md:38-47`,
  `b1-rpc-private-calc-aggregate-exfiltration.md:76-77`

The index says there are two explicit exemptions from the "must fail on unfixed
code" rule, and then enumerates only B1's #27 half, L12 items 3/4/5/8, docs-only
confirmations, and P5's non-runtime parts. A0/R0 still require additional
retained regressions for items already fixed by earlier work: MDL #22,
`default_can?` #20, upsert arity guards, and ash_remote #6/#9/#10/#11/#26 plus
non-string `schema_version`. B1 also requires retaining the first-run
private-attribute regression.

Those retained tests are expected to pass on the current tree, but the index's
closed exemption list does not include them. That makes task closure ambiguous:
an implementer following the index literally could either reject valid retained
tests for not failing first, or skip them because they are not named in the
exception list.

**Recommendation**: broaden the index exemption to cover all "landed but
untested" retained regressions named by A0/R0/B1, or explicitly state that those
tests must fail only against a historical unfixed baseline and are expected to
pass on the current working tree.

### Medium - Checkpoint-commit prerequisite is tracked only in FINAL, after tasks that need it

- **Task refs**: `00-index.md:188-194`, `final-gates.md:3`,
  `final-gates.md:51-58`, `b1-rpc-private-calc-aggregate-exfiltration.md:71-77`,
  `l12-mdl-misc-lows.md:57-59`, `a0-mdl-repro-harness.md:35-45`,
  `r0-ash-remote-repro-harness.md:38-48`

The index says to make a checkpoint commit before executing retained-regression
items because several fixes exist only in the uncommitted working tree. The only
closeable owner is `FINAL`, but `FINAL` must be the last task closed. Several
earlier tasks require retained regressions before they can close.

That sequencing lets implementers reach and execute retained-regression work
before the prerequisite is visible in their active task. The gate is tracked, but
tracked too late.

**Recommendation**: move the checkpoint requirement to an explicit preflight task
or duplicate it into each retained-regression task's `Done when` section. If it
is only advisory, soften the index/final wording so it is not a required-but-late
gate.

### Medium - M3's fix text asks for an after-image that `forget!/3` cannot pass

- **Task refs**: `m3-external-update-after-image-row-before.md:30-35`
- **Source refs**: `lib/ash_multi_datalayer.ex:52-57`,
  `lib/ash_multi_datalayer.ex:61-64`,
  `lib/ash_multi_datalayer/orchestrator/proven_coverage.ex:172-180`

M3 correctly identifies that external update notifications pass the after-image
as `row_before`. Its fix then says the change is "one line" via
`Map.take(record, primary_key)` and also says to "pass the record as the
after-image where the invalidation math wants it." The current `forget!/3` API
always computes `row_before` and calls `Invalidation.on_write(resource, tenant,
row_before, nil)`. It has no way to pass a `row_after` without changing the API
or bypassing `forget!/3` at `handle_external_change/2`.

The task therefore mixes two different fixes: a PK-only unknown-before probe, and
a before/after invalidation call. A fixer could implement only the one-line probe
and not satisfy the stated after-image requirement, or change the API when the
intended fix was only conservative PK invalidation.

**Recommendation**: choose the intended behavior explicitly. If PK-only unknown
before-image is enough, remove the after-image phrase. If update invalidation
must pass both sides, require the necessary `forget!/3`/`handle_external_change/2`
API change and test both filter-exit and filter-enter cases.

### Medium - P6 tenant-sweep repro can lose its fail-first baseline if H5 lands first

- **Task refs**: `00-index.md:167-171`, `p6-lost-kick-recovery.md:43-45`,
  `p6-lost-kick-recovery.md:49-64`

The recommended order fixes the tenant unit, including H5, before the remaining
HIGH items such as P6. P6 requires repros to fail against the current
working-tree code and includes a multitenant sweep repro that fails "if the H5
nil-tenant model hides them." If H5 is fixed first, that tenant-specific P6 repro
may no longer fail for the reviewed reason.

This creates a sequencing trap: following the recommended order can make part of
P6's fail-first criterion impossible or force implementers to recreate an older
H5-broken baseline.

**Recommendation**: clarify that the P6 multitenant-sweep case becomes a retained
passing regression after H5, or require a sweeper-specific failing repro that is
independent of H5's nil-tenant defect.

### Low - B2 does not define the loader/generator boundary for unsafe aggregate filters

- **Task refs**: `b2-aggregate-filter-codegen-injection.md:36-48`

B2 says unsafe aggregate filters should "fall back to `remote(...)` proxies," but
the done criteria also require a "Loader-level validation test for
`aggregate_filter` pass-through." It is unclear whether the loader should reject
unsafe manifest input, preserve it for the generator to proxy, or only validate
shape/type while leaving safety to the generator.

**Recommendation**: state the intended boundary explicitly: unsafe filters are
accepted by the loader and proxied by the generator, rejected by the loader with a
typed error, or accepted only when `safe?` passes. Then make the loader-level test
assert that exact behavior.

### Low - L2's flaky-test gate is not measurable

- **Task refs**: `l2-aggregate-fold-notloaded.md:29-33`

L2 requires `example/todo_client` `live_test.exs:92` to "no longer flake (run
repeatedly)." Without a command, seed policy, or repetition count, two reviewers
can close or reopen the task based on different evidence.

**Recommendation**: make the gate concrete, e.g. name the exact test command and
repeat count, or replace the flaky-live-test gate with the focused deterministic
repro from the first checkbox.

### Low - L9 is partly docs-only, but the index wording can make the whole task look repro-exempt

- **Task refs**: `00-index.md:55-61`,
  `l9-destroy-notification-drop-docs.md:21-30`

The index lists "the L9/L10 doc items" as docs-only confirmations with no failing
repro. L9, however, also requires confirming LifecycleGuard coverage or recording
a follow-up. That second checkbox is not purely a documentation confirmation.

**Recommendation**: clarify the exemption as "L9's documentation checkbox only";
LifecycleGuard coverage or the deferred follow-up still has to be explicitly
closed.

### Low - A0's "Final gate 5" reference is ambiguous against this tracker

- **Task refs**: `a0-mdl-repro-harness.md:20-23`, `final-gates.md:32-35`

A0 says changeset-less notification tenant tests are "Final gate 5." In this
tracker's `final-gates.md`, tenant-strategy tests are gate 4; gate 5 is the
semantic docs sweep. The intended reference appears to be the plan's Final gate 5,
but the local tracker numbering points elsewhere.

**Recommendation**: change A0 to "plan Final gate 5" or reference
`final-gates.md` gate 4 directly.

### Low - L13 revocation refs omit the file that defines the default socket id

- **Task refs**: `l13-ash-remote-server-realtime-lows.md:17-18`
- **Source refs**: `../ash_remote/lib/ash_remote/server/channel.ex:49-52`,
  `../ash_remote/lib/ash_remote/server/socket.ex:89-90`

L13 cites `channel.ex:49` and "default `socket id/1 -> nil`" together. The first
reference is the join-time read-scope assignment; the default socket id lives in
`server/socket.ex:89-90`. The task is directionally correct, but the source refs
send implementers to only half of the revocation posture.

**Recommendation**: include `server/socket.ex:89-90` in L13's source references.

### Low - FINAL's changelog/decision-log gate names files that do not all exist

- **Task refs**: `final-gates.md:46-49`
- **Filesystem refs**: `CHANGELOG.md` exists in MDL; `DECISIONS.md` exists in
  `../ash_remote`; MDL `DECISIONS.md` and ash_remote `CHANGELOG.md` are absent.

The gate says both repos' CHANGELOG/DECISIONS must be updated. Current repo roots
do not have all four files, so implementers have to guess whether missing files
should be created or whether the gate means "update whichever of these logs
exists in each repo."

**Recommendation**: specify the exact expected files, or state that missing logs
should be created only if the corresponding repo has release/decision content to
record.

## Summary

- New blocker/high findings: none.
- Findings raised: 10 total - 4 Medium, 6 Low.
- Most prior review findings appear incorporated; the remaining issues are
  sequencing, fail-first semantics, and acceptance-criteria precision rather than
  task coverage gaps.
