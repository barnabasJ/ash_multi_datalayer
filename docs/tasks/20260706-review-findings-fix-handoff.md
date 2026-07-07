# Handoff: implement the 2026-07-06 review-findings fix plan

You are implementing the reviewed fix plan for ash_multi_datalayer and
ash_remote. All design work is **done, reviewed (4 rounds, 10 passes, converged
— final verdict "Ship it"), and green-lit** — your job is implementation, not
redesign. If you find yourself redesigning, stop and re-read the plan; every
decision, including several that were overturned and re-decided, is recorded
with its rationale in the plan's Review disposition.

**Working directory**: the `ash_multi_datalayer` repo root. Sibling repo:
`../ash_remote` (Workstream B lives there).

## Read these, in order, before writing any code

1. `docs/plans/20260706-review-findings-fix-plan.md` — **the plan, in full**,
   including the **Facts** section (source-verified ground truth at
   ash_multi_datalayer `e0c0ed1` / ash_remote `621129b` — re-verify a fact only
   if the tree has moved past those commits) and the **Review disposition** (why
   each design is the way it is; do not re-litigate).
2. `docs/reviews/20260706-whole-repo-review.md` — the findings being fixed (IDs
   M-1…M-12, R-1…R-11), each with location, failure scenario, and fix direction.
3. The per-round review docs (`docs/reviews/20260706-*plan-review*`) only when a
   plan step cites one and you need the full argument.

## Execution order

- **Workstream A** (this repo): A0 → A1 → A2 → A3 → A4. **A5 is NOT part of this
  task** (separate arc).
- **Workstream B** (`../ash_remote`): B0 → B1 → B2 → B3, in parallel with A or
  after it.
- **The one cross-repo coupling**: land B2-1 (`AshRemote.Error.Transport`)
  **before or together with** A2, or have A2's `classify/1` accept both the old
  raw tuples and the new Transport error during the overlap.

## Discipline (non-negotiable)

- **Repro-first**: build each phase's harness tests first and confirm they fail
  _for the plan's stated reason_ before fixing. A0 tests 1–6 and the B0 tests
  must fail pre-fix; A0-7/A0-8 and the A0-2 materialization/partial-select
  sub-assertions are gap-fill/arbitration — expected green pre-fix, must stay
  green post-fix. Never weaken a failing harness test to make it pass; if a test
  fails for a _different_ reason than the plan states, stop and reconcile
  against the plan's Facts before proceeding.
- **Run the gates**: each phase ends with its stated gate (named tests + full
  `mix test` in the touched repo; credo where the gate says so). Do not start
  the next phase on a red gate.
- **Commit per phase** (A0, A1, … each at least one commit) with messages naming
  the phase and finding IDs. Do not push unless asked.
- The plan's step text is the spec — it encodes hard-won corrections (e.g.
  rebase captures entry IDs because `drop_chain` cannot distinguish fresh
  entries; write_through pushes only loaded fields ∪ changed ∪ PK, never
  `%Ash.NotLoaded{}`; the atomics guard checks BOTH `changeset.atomics` and
  `changeset.create_atomics`; `discard/1` must become idempotent; reconcile
  eviction drops covering entries via one batched ledger scan, not a bare epoch
  bump). When your instinct disagrees with the plan, the plan has already been
  through that argument — follow it, and note the disagreement in your final
  report if it still bothers you.

## Out of scope — do NOT implement

- Phase A5 (Phase 4a consolidation) — separate arc.
- `docs/design/20260706-atomic-capability-delegation-rfc.md` — filed follow-up,
  sequenced after A5.
- The stacked-orchestrators RFC (exploratory).
- M-12's declared follow-ups (`SqlPassthrough` error-branch tests,
  `RemoteContext` flush-threading tests) and anything for M-7 beyond the A4
  documentation task.

## Final gate (after both workstreams)

1. `mix test` green in **both** repos — in ash_multi_datalayer including the
   `:integration` tagged set.
2. The offline-first example demo runs end-to-end per
   `../ash_remote/example/README.md` (online invalidation; offline edit →
   conflict → resolve via **each** verb including the fixed `rebase`; refresh).
   Mind the demo's boot notes (ports, stale processes, `deps.compile`); **never
   restart or reconfigure shared Postgres or containers** — if the demo's
   database isn't reachable, report it instead of "fixing" infrastructure.
3. The docs sweep listed in the plan's final gate (moduledocs changed by
   semantics — write_through spec promoted to the moduledoc, classify/park
   classes, upsert collision note, realtime field stripping; the guide's
   strategy section; the runbook's LocalOutbox section incl. the `:auth` park
   class; both repos' CHANGELOG/DECISIONS).

## Report at completion

One report at the end (no mid-task check-ins): per phase — gate status, test
counts, and any deviation from the plan with its justification; plus the
final-gate evidence (suite outputs, demo walkthrough results). If a genuine
blocker forces a design change, stop and surface it rather than improvising
around it.
