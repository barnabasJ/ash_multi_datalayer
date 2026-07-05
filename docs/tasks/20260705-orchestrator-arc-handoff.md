# Handoff: execute the orchestrator extraction + LocalOutbox arc

You are picking up the ash_multi_datalayer orchestrator arc. All design and
planning is **done, reviewed (7 converged review passes), and green-lit** —
your job is implementation, not redesign. If you find yourself redesigning,
stop and re-read the relevant doc; the answer is almost certainly recorded.

**Working directory**: `/home/joba/sandbox/ash_multi_datalayer`. Sibling
repos used by later phases: `../ash_remote` (Phase 6 fold-in target),
`../ash_remote_cache` (Phase 6 dissolves its lib; Phase 7 builds out its
example).

## Read these, in order, before writing any code

1. `docs/plans/orchestrator-extraction-and-local-outbox-plan.md` — **the
   plan**. Phases 0–8, each with deliverables and a checkable gate. Its
   "Facts" section is the distilled, source-verified gotcha list — trust it.
2. `docs/design/20260705-orchestrator-behaviour-adr.md` — the behaviour seam
   (13 callbacks) + the capability-derivation rules (feature classes,
   bypass-guards).
3. `docs/design/20260705-sync-state-as-ash-resources-adr.md` — why outbox
   state is app-owned Ash resources on Oban/ash_oban (note the footnoted
   sweep-worker exception to "no scheduler").
4. `docs/design/20260705-local-outbox-orchestrator-rfc.md` — the
   **normative spec** for Phase 4 (write path, flush triage, dirty-chain
   rule, resolution verbs, per-action targeting, kill switch).
5. Context for the code you'll move: `docs/plans/critical-bugs-fix-plan.md`
   and `docs/reviews/20260704-implementation-review.md` (the fixes are
   already landed — you are moving *fixed* code).

`docs/design/20260705-stacked-orchestrators-rfc.md` is **exploratory /
post-arc**: do NOT implement it. Phase 1 carries only its boundary-funneling
note.

## Repo state at handoff

- Branch from HEAD (`f5f9a89`). The critical-bugs fix plan is fully landed
  (`b290e0d`), `forget!/3` exists at `lib/ash_multi_datalayer.ex:53`, the
  tree is clean except **untracked docs**.
- **First action**: commit the untracked `docs/design/`, `docs/plans/`,
  `docs/reviews/`, `docs/tasks/` files (one or two commits) so the branch
  carries its own rationale, then branch for Phase 1.

## Hard constraints (CLAUDE.md house rules + plan)

- **No hex.pm access in this sandbox.** Every dep is in
  `~/.hex/packages/hexpm` at the versions pinned in the plan's facts (oban
  2.23.0, ash_oban 0.8.10, ash_sqlite 0.2.17, exqlite, igniter 0.8.2,
  phx_new 1.8.x, oban_web 2.12.5, oban_met 1.2.0). Pin exact versions like
  the existing `crux` pin. phx.new must run `--no-assets` (asset pipeline
  downloads binaries).
- **Docs before code on any deviation.** If a Phase 2 spike answer
  contradicts the plan/RFC, update the doc + the plan's Addendum section
  first, then implement.
- **Full tests after changes**: `mix test && INTEGRATION=1 mix test`.
  Compiling clean is not done. Investigate failures (same seed, isolation)
  before calling anything flaky.
- `lib/` stays data-layer agnostic (behaviour surface only; the AshPostgres
  migration shim is the one sanctioned exception).
- Work the phases **in order and to completion** — every gate green before
  the next phase; no scope-trimming, no "representative subset", no
  stopping to ask whether to continue. Stop only for genuine blockers or
  decisions that are truly the user's.

## Execution order

Phase 1 (pure-refactor extraction) and Phase 2 (Oban/ash_oban/SQLite
walking skeleton, 11 numbered items — record every answer in the plan's
Addendum) are independent of each other; then 3 (OutboxEntry extension +
igniter generators) → 4 (LocalOutbox strategy) → 4a (shell increments +
capability derivation) → 5 (ledger-as-resource, benchmark-gated) → 6 (fold
ash_remote_cache's lib into ash_remote as unnamed utilities) → 7 (flagship
example: mixed strategies + full conflict-resolution UI + two-instance
e2e) → 8 (docs closure).

## Traps already discovered — do not rediscover them

All are in the plan's facts section with file:line sources:

- **Phase 1 is gated pure.** The strategy-specific DSL keys stay as
  section-level **aliases** forwarding into orchestrator opts (removal is a
  Phase 4a act). The test suite must pass **unchanged**; put the
  positional-site → funnel-function mapping table in the commit message.
- **ash_sqlite hardcodes `can?(:transact) == false`.** Co-commit = same
  Ecto repo + raw `Repo.transaction/1`. Never gate on the Ash capability.
- **ash_oban 0.8.10 cannot enqueue into a named Oban instance.** One MDL
  enqueue helper, **four** call sites: immediate kick, sweep worker,
  chain-continuation in `Flush.run/2`, retry re-trigger. Never call
  `AshOban.run_trigger/3` from library code — it lands in the default
  instance and stalls chains. `scheduler_cron false` on the trigger.
- **`put_dynamic_repo` is per-process, not inherited.** Workers establish
  repo + instance from `job.conf.name` as `Flush.run/2`'s **first act**
  (source-verified: generic-action triggers run no read before the action);
  caller processes get both from the instance plug/hook; strategy processes
  from `child_specs/1` opts.
- **Oban has no FIFO, even at concurrency 1.** Per-PK ordering lives in the
  flush action's chain-head check on `seq` — never in queue config. `seq`:
  integer PK/rowid preferred (Phase 2 item 9).
- **Offline-class flush errors snooze** via `AshOban.Errors.SnoozeJob`
  (re-schedules AND increments max_attempts — zero budget burn, verified).
  Triage: offline → snooze; transient-while-connected → raise/retry;
  rejection/conflict → park immediately.
- **ash_sqlite answers TRUE to `update_query`/`destroy_query`/atomics.**
  The orchestration-bypass guards stay hardcoded false regardless of layer
  support — that's load-bearing, not a smell.
- **Refresh must skip dirty PK chains** (non-empty outbox chain → skip),
  or it clobbers unflushed local writes and the flush pushes stale payloads
  back.

## Working rhythm

Per phase: implement → run the gate literally as written → update the
plan's status/Addendum → commit with the phase name → next phase. The
review series (`docs/reviews/20260705-orchestrator-extraction-*`) is the
audit trail if you need the "why" behind any decision.

---

**Created**: 2026-07-05 (handoff from the design/planning sessions)
