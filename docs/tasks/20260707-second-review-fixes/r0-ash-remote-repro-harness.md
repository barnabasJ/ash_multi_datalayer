# R0 — Build the ash_remote repro/regression harness the plan mandates

- **Status**: OPEN
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
