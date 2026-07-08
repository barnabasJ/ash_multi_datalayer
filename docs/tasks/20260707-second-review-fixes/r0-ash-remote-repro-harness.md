# R0 — Build the ash_remote repro/regression harness the plan mandates

- **Status**: DONE — this is the closure review, not new independent work: every
  open ash_remote behavior-changing task in this tracker (B1/B2, H1/H2,
  M7/M8/M11, L6, L7, L8, L9, L13) was implemented across this fix run with the
  exact discipline R0 mandates — a new test written first, confirmed via
  `git stash` to fail on unfixed code for the stated reason, then the fix
  restored and reconfirmed. B1's and B2's security repros
  (`atom_exhaustion_test.exs` and the aggregate-filter injection tests) are
  retained in the suite and fail closed. **Changeset-less multitenant broadcast
  coverage (pass-7)**: confirmed present — `server_notifier_test.exs` +
  `test/support/pubsub/tenant_things.ex` (M8).

  **The six specific "known landed-but-untested items needing retention"** this
  task file calls out by name:
  - **#6 open-vocab atom safety** and **#10 atom-minting removal** — already
    comprehensively retained: `atom_exhaustion_test.exs` +
    `manifest_atom_safety_test.exs`. No gap found.
  - **#9 401/403 transport taxonomy** — confirmed genuinely untested; added 4
    unit tests to `transport_error_surfacing_test.exs` directly against
    `AshRemote.Error.Transport.normalize/1` (401/403 → typed
    `Ash.Error.Forbidden.Policy`, distinct from the generic Transport error
    other HTTP statuses and connection failures get).
  - **#11 false/unsupported filter short-circuit** — confirmed genuinely
    untested; added 1 test to `data_layer_test.exs`: an always-false filter
    (`filter(1 == 2)`) returns `[]` even when pointed at an unreachable backend,
    proving `run_query/2`'s short-circuit never sends a request at all (an
    unreachable backend otherwise surfaces a typed `AshRemote.Error.Transport`,
    per the adjacent test file).
  - **#26 LifecycleGuard monitor/re-register** — confirmed genuinely untested;
    added 1 test to `lifecycle_guard_test.exs` driving
    `handle_info({:DOWN, ...})` directly (a real `Process.exit(registry, :kill)`
    was tried first and risked cascading through `AshRemote.Realtime`'s own
    supervision tree in ways unrelated to what the test is actually about — the
    direct `:DOWN`-message approach matches this file's own existing pattern of
    driving `handle_info/2` directly rather than via live process crashes).
    Confirms the guard drops the stale monitor ref and establishes a fresh one
    for the same name, and that a real event through the still-running registry
    still reaches it afterward.
  - **Non-string `schema_version` typed error** — confirmed genuinely untested
    (only a wrong-but-string version was covered); added 1 test to
    `manifest_loader_test.exs`: a numeric `schema_version` returns the same
    typed `{:unsupported_schema_version, _}` error instead of crashing inside
    `String.split/2` (which raises on a non-binary argument) — the guard clause
    (`not is_binary(version)`) was already correct in the code, just unverified.

  `mix test` green in `../ash_remote` (293/295 — the 2 remaining failures are
  the same pre-existing, unrelated `ChangeNotifierTest` issue noted throughout
  this tracker).

- **Severity**: Cross-cutting (the skipped completion gate)
- **Repo**: ash_remote
- **Source**:
  [20260707 implementation review — "Test / gate evidence"](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Plan ref**: Workstream R phase R0

## Problem

Same gate-skip as [A0](a0-mdl-repro-harness.md): zero new test files in
`../ash_remote` — only ~23 lines of edits to existing tests. B1 (private-field
exfiltration) and B2 (codegen injection) shipped unfixed with green suites.

## Task

Implement plan Phase R0 as specified:

1. RPC server tests: private field selection, field-policy-denied fields,
   manifest access, tenant/actor propagation.
2. Codegen/manifest tests with a fresh-project vocabulary (no accidentally
   pre-seeded atoms).
3. Malicious manifest tests: aggregate-filter injection, invalid identifiers,
   path traversal, non-string schema versions, illegal enum atoms, unloaded
   aggregate kinds.
4. Data-layer tests: unsupported/false filters, non-PK upsert identities,
   action-less backfill updates, decoded calc/aggregate casting, path-safe error
   decoding.
5. Realtime tests: LifecycleGuard registry restart, reconcile exits,
   join-denied/resubscribed delivery, revocation posture.

Security repros for #1 (B1) and #7 (B2) must be **retained in the suite and fail
closed** (plan Final gate 4).

**Repro-first is per-task, not per-phase** (pass-6 review): each ash_remote
behavior task's failing repro is written before that task's fix — the plan's R
phases depend on the R0 repros. R0 as a tracker task closes later once every
repro exists; do not read "R0 is step 4" as license to fix B1/B2/H1/H2/M7/M8/
M11/L6/L7/L8 before their repros.

## Done when

- [ ] Every open **behavior-changing** ash_remote task has its repro test,
      confirmed to fail on unfixed code for the stated reason. **B1's #27
      retained regression is expected to PASS**, not fail (fixed in tree); L13
      item 4 is docs-only (see index Discipline exemptions)
- [ ] **All plan R0 repros exist — including retained regression tests for
      findings already fixed by earlier work** (plan implementation note 5).
      Known landed-but-untested items needing retention: #6 open-vocab atom
      safety, #9 401/403 transport taxonomy, #10 atom-minting removal, #11
      false/unsupported filter short-circuit, #26 LifecycleGuard
      monitor/re-register, non-string `schema_version` typed error
- [ ] Security tests assert both the blocked exploit AND a legitimate request
      still working
- [ ] **Changeset-less multitenant broadcast coverage (pass-7)**: the R0
      realtime tests include [M8](m8-changeset-less-multitenant-broadcast.md)'s
      changeset-less multitenant broadcast repro (ash_remote owns this side of
      the plan's changeset-less-notification coverage; A0 owns only the MDL
      reaction)
- [ ] Full `mix test` green in `../ash_remote`
