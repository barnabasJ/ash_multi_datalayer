# A0 — Build the MDL repro/regression harness the plan mandates

- **Status**: OPEN
- **Severity**: Cross-cutting (the skipped completion gate)
- **Repo**: MDL (ash_multi_datalayer)
- **Source**:
  [20260707 implementation review — "Test / gate evidence"](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Plan ref**: Workstream A phase A0 (full spec: 20 named failing repros)

## Problem

The plan's mandatory repro-first discipline was skipped: **zero new test files
in either repo** — only ~37 lines of edits to existing MDL tests. This is the
direct reason B1, B3, B4, B5, B6 shipped looking correct: nothing exercises them
against real inputs, and the green suites run on the single-tenant SQLite stack,
which structurally avoids the tenant-partition defects.

## Task

Implement plan Phase A0 as specified: targeted integration tests under
`test/integration/` for ProvenCoverage races, tenant invalidation (context
struct tenants, attribute tenancy, and the **MDL-side handling of** changeset-
less notifications — **the plan's Final gate 5**, this tracker's
[final-gates.md](final-gates.md) **gate 4**), LocalOutbox recovery/resolution,
and propagation field handling, plus the focused unit tests. Reuse existing
blocking/stub layer support; add only the minimal helpers needed to force the
reviewed race windows.

> A0 covers the **MDL** side of changeset-less notifications only (how MDL
> reacts to a received notification). The **ash_remote** side — the
> changeset-less multitenant _broadcast_ reaching subscribers — is owned by
> [M8](m8-changeset-less-multitenant-broadcast.md) via R0 (pass-7 review).

Each behavior-changing task carries its repro criterion; **where a task cites a
numbered "plan A0 repro N", that's its anchor** (not every task cites one —
pass-7). **Repro-first is per-task, not per-phase** (pass-6 review): write and
confirm-failing each task's repro _before_ that task's fix. The index lists A0
at step 4 for fix _dependency priority_ only — NOT license to fix
B1/B2/tenant-unit/B4–B7 before their repros exist. This A0 task (the overall
harness) closes later, once every task's repro plus the retained regressions are
in place; the individual repros land with their fixes throughout.

## Done when

- [ ] Every open **behavior-changing** MDL task has its repro test, confirmed to
      fail on unfixed code for the stated reason. **Retained-regression items
      (fixed in tree) are expected to PASS, not fail** — they are kept as
      regressions, not held to the "must fail first" clause (see index
      Discipline exemptions); docs-only items have no repro
- [ ] **All plan A0 repros exist — including retained regression tests for
      findings already fixed by earlier work** (plan implementation note 5:
      "keep or add the regression test and mark the item verified"). Known
      landed-but-untested items needing retention: the #22 authority-order
      verifier (`validate_layers.ex:146-157`), the `default_can?` tightening
      (#20), and the upsert arity guards (B1 first-review)
- [ ] Race fixes prove the reviewed interleaving, not just the happy final state
- [ ] Tenant-strategy tests run on a multitenant stack, not only single-tenant
      SQLite
- [ ] `INTEGRATION=1 mix test` green in MDL
