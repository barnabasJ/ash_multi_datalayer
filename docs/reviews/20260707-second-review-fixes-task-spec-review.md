# Task-spec review: 2026-07-07 second-review fixes

**Subject**: `docs/tasks/20260707-second-review-fixes/`
**Reviewer**: task-spec consistency and executability pass
**Result**: coverage against the source implementation review appears complete, but several task specs need correction before execution to avoid impossible tests, ambiguous closure, or unsafe acceptance criteria.

## Findings

### High - B1 requires an `Ash.NotSelected` regression case that does not exist in the checked dependency

- **Task refs**: `docs/tasks/20260707-second-review-fixes/b1-rpc-private-calc-aggregate-exfiltration.md:40`, `:49-50`, `:57`, `:68`
- **Code refs**: `../ash_remote/deps/ash/lib/ash/not_loaded.ex:5`, `../ash_remote/deps/ash/lib/ash/forbidden_field.ex:5`

B1 requires serialization coverage for `%Ash.NotSelected{}` and explicitly asks for a `%Ash.NotSelected{}` test case, but the checked Ash dependency defines `%Ash.NotLoaded{}` and `%Ash.ForbiddenField{}`; no `Ash.NotSelected` module is present. That makes the acceptance criterion non-compiling as written and can block the highest-priority security fix for the wrong reason.

Clarify the intended sentinel. If the real skipped-field value is `%Ash.NotLoaded{}`, B1 should require `ForbiddenField` plus `NotLoaded`; if some Ash version can emit `NotSelected`, the task needs a version-specific note or conditional coverage path.

### Medium - The global repro-first rule conflicts with retained-regression and docs-only tasks

- **Task refs**: `docs/tasks/20260707-second-review-fixes/00-index.md:39-43`, `:152-156`; `docs/tasks/20260707-second-review-fixes/a0-mdl-repro-harness.md:35-42`; `docs/tasks/20260707-second-review-fixes/r0-ash-remote-repro-harness.md:38-45`; `docs/tasks/20260707-second-review-fixes/l13-ash-remote-server-realtime-lows.md:27-30`

The index says the failing-repro gate applies to every task, and A0/R0 require every open repo task to have a repro confirmed to fail on unfixed code. The same index explicitly says some retained regressions are already fixed in the working tree and should be kept even if they pass, and L13 item 4 is a docs-sweep confirmation only.

This makes A0/R0 impossible to close literally. Scope the failing-repro requirement to behavior-changing open defects, and explicitly exempt retained-regression items expected to pass on current code plus docs-only confirmations.

### Medium - B5's compile-failure acceptance criterion ignores the tracked verifier posture

- **Task refs**: `docs/tasks/20260707-second-review-fixes/b5-validate-aggregate-overrides-regression.md:21-25`, `:33-36`; `docs/tasks/20260707-second-review-fixes/p2-verifier-compile-posture.md:17-28`
- **Code refs**: `test/ash_multi_datalayer/verifiers_test.exs:1-5`

B5 says a bad `local_evaluation_overrides` case fails compilation and asks for a repro that fails with a compile error on unfixed code. P2 and the existing verifier tests document that Spark verifier failures are surfaced as diagnostics/warnings under plain compile unless `--warnings-as-errors` is used, and the tests call verifiers directly for that reason.

Make B5's acceptance criterion match the actual posture: assert `ValidateAggregateOverrides.verify/1` directly, or run an explicit `--warnings-as-errors` compile test. As written, the repro can pass or fail for the wrong compile-posture reason.

### Medium - H1 omits explicit context-header propagation from the required tests

- **Task refs**: `docs/tasks/20260707-second-review-fixes/h1-remote-calc-fetch-unauthenticated.md:30-39`
- **Plan ref**: `docs/plans/20260706-second-review-findings-fix-plan.md:471-473`

H1 says the fix must thread actor/context and build headers through `request_headers(context)`, but the done criteria only require an actor-auth header and tenant threading. `request_headers(context)` also carries explicit configured context headers; a fix could pass the actor-token test while still dropping caller-supplied headers for bundled remote calculations.

Add an assertion that `context: %{ash_remote: %{headers: ...}}` reaches the bundled remote-calculation request, not just actor-derived authorization and tenant data.

### Medium - M8 allows an unobservable "documented reconcile" completion path

- **Task refs**: `docs/tasks/20260707-second-review-fixes/m8-changeset-less-multitenant-broadcast.md:25-36`
- **Plan refs**: `docs/plans/20260706-second-review-findings-fix-plan.md:515-528`

M8's done criterion allows a changeset-less multitenant mutation to either reach tenant subscribers or "trigger the documented reconcile," but it does not name an observable signal, event, reconnect, or guard behavior. That can turn a lost-notification bug into a docs-only closure.

Require a concrete assertion: tenant-topic delivery, a specific LifecycleGuard/gap/reconcile event, or another testable reconnect mechanism. The unfixed-code failure should be "no delivery and no reconcile signal," not just "delivering nothing."

### Medium - M11 does not require the data-layer return shape for single-object reads

- **Task refs**: `docs/tasks/20260707-second-review-fixes/m11-decoder-crashes-nil-single-object.md:31-44`

M11 requires a bare single object to "decode without crashing" and calls it a "single-record decode," but it does not require `run_query/2` to return the list shape the Ash data layer expects. A wrong fix could return a struct directly for a `get?` hit and still satisfy the current wording.

Specify exact outcomes: a `get?` hit decodes to a one-element list, a legitimate `get?` miss decodes to `[]`, and malformed missing/null list responses return typed protocol errors.

### Medium - L8 under-specifies authorization coverage across RPC paths

- **Task refs**: `docs/tasks/20260707-second-review-fixes/l8-rpc-authorize-flag.md:9`, `:19-26`

L8 states every server-side Ash call in RPC dispatch needs `authorize?: true`, but the file mapping and test criterion can be satisfied by a single unauthorized RPC case. RPC create/update/destroy paths and any helper fetches used by update/destroy need the same explicit authorization behavior, otherwise a partial fix can leave policy bypasses behind.

Require coverage for read, create, update, destroy, and fetch-helper paths, or explicitly document any excluded paths and why they cannot bypass policies.

### Medium - L12 item 6 can be closed without deciding whether upsert stale-check bypass is sound

- **Task refs**: `docs/tasks/20260707-second-review-fixes/l12-mdl-misc-lows.md:34-36`, `:48-57`
- **Plan refs**: `docs/plans/20260706-second-review-findings-fix-plan.md:263-268`

L12 says the `:upsert` stale-check bypass needs a "Doc note at minimum," while the plan requires documenting semantics or adding an explicit guard if the current behavior is unsound. The checklist does not require proving that last-writer-wins overwrite is acceptable for configured targets, nor a regression if the behavior is guarded.

Add an explicit decision point: either document why `:upsert` LWW is intentionally safe for the supported target modes, or add a guard plus a focused regression proving diverged remote rows are not silently overwritten.

### Low - FINAL's first closure criterion is self-referential

- **Task refs**: `docs/tasks/20260707-second-review-fixes/00-index.md:129`; `docs/tasks/20260707-second-review-fixes/final-gates.md:3`, `:51-57`

`FINAL` is itself an open tracker task and must be the last task closed, but its first done criterion says all open tasks in the tracker are DONE, WONTFIX, or deferred. Read literally, that includes `FINAL` itself and cannot be satisfied.

Change the criterion to "all other open tasks" or explicitly exclude `FINAL` from that checklist item.

### Low - The checkpoint-commit prerequisite has no owner or closeable gate

- **Task refs**: `docs/tasks/20260707-second-review-fixes/00-index.md:158-163`; `docs/tasks/20260707-second-review-fixes/final-gates.md:51-57`

The index imperatively says to make a checkpoint commit before executing retained-regression items because the fixes are only in the uncommitted working tree. No task row or final-gate checklist item tracks whether that prerequisite happened, was skipped by decision, or was blocked.

If this is binding, add it to `FINAL` or a dedicated prep task. If it is advisory, soften the language so implementers do not treat an untracked prerequisite as required but unverifiable.

### Low - L5 suggests hiding a multi-node boot failure and lacks a collision-focused acceptance test

- **Task refs**: `docs/tasks/20260707-second-review-fixes/l5-sweeper-global-name-multinode.md:22-35`

L5 lists "ignore `already_started`" as a possible multi-node-safe fix for the global sweeper name collision. By itself, that can hide the second-node supervisor failure while leaving no supervised local sweeper or failover story on the second node. The done criteria only say the supervisor starts cleanly, not that the second-node/global-name collision is reproduced and resolved according to the chosen posture.

Require either a hard-reject test that proves multi-node startup is rejected before the sweeper collides, or a true multi-node/failover/idempotent-per-node test that proves the selected sweeper behavior is safe.

### Low - L7 header-dedupe test does not require the explicit precedence rule

- **Task refs**: `docs/tasks/20260707-second-review-fixes/l7-data-layer-lows.md:16-19`, `:28-31`
- **Plan refs**: `docs/plans/20260706-second-review-findings-fix-plan.md:481-483`

The defect text and plan call for case-insensitive authorization-header dedupe with an explicit precedence rule, but the checklist only requires a test with both static and actor tokens. A test that only checks dedupe happened can pass with arbitrary or unstable winner selection.

Add an assertion for the chosen precedence rule, including case-insensitive duplicate names.

### Low - L6 path-traversal repro wording can encourage unsafe filesystem effects

- **Task refs**: `docs/tasks/20260707-second-review-fixes/l6-codegen-lows.md:18-21`, `:28-32`

L6 says malicious traversal-path tests fail on unfixed code by generating bad files/paths. That is useful as a repro signal, but the task does not state that the repro must run in a temp sandbox or assert that no file escapes the configured output root after the fix.

Make the filesystem safety boundary explicit: traversal repros should use a temporary output root or dry-run/check mode, and the post-fix assertion should include "no path escaped the configured root."

## Non-findings

- I did not find missing source-review coverage. The tracker appears to map the open implementation-review findings to task files, `deferred-follow-ups.md`, or `final-gates.md`.
- I did not find broken markdown links or obvious repo/status/severity table mismatches in the reviewed task set.
