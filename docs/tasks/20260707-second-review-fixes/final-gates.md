# FINAL — Plan final gates: demo exercise, docs sweep, closure checks

- **Status**: OPEN — must be the LAST task closed; blocks tracker closure
- **Severity**: Cross-cutting (the plan's completion bar)
- **Repo**: both
- **Source**:
  [plan Final gates](../../plans/20260706-second-review-findings-fix-plan.md)
  (items 1–6); first-plan handoff final gate; added per
  [pass-3 coverage review F1](../../reviews/20260707-second-review-fixes-task-coverage-review-3.md)

## Why this task exists

Every other task can be individually DONE while the cited plan is still below
its completion bar — the plan's final gates are cross-cutting and were
previously owned by no task. The tracker may not be declared closed until this
task is done or each unmet gate is explicitly reported blocked (with what
blocked it).

## Gates (from the plan, plus the first-plan handoff)

1. `INTEGRATION=1 mix test` green in MDL and `mix test` green in `../ash_remote`
   — final joint run, both repos at their end state.
2. **Offline-first example exercised end-to-end** per
   `../ash_remote/example/README.md`: online invalidation; offline edit →
   conflict → resolve; refresh. **Verb coverage split (loop-5 review — the demo
   UI does not expose every verb)**: the demo `offline_live.ex` renders buttons
   only for **`retry`, `force`, `discard_local`** (`:268-277`); `discard` is a
   hidden event handler (`:161-166`) and **`rebase` has no UI at all** (only
   `LocalOutbox.rebase/2` with a required changeset, `api.ex:235-258`). So
   exercise `retry`/`force`/`discard_local` through the demo UI, and cover
   `discard` and `rebase` through the **resolution test suite / direct API**
   (`local_outbox_resolution_test.exs`) — do NOT block trying to click a
   `rebase` button that does not exist, and do NOT mark the gate done with
   `discard`/`rebase` unexercised. Mind the demo's boot traps (ports, stale beam
   processes, `deps.compile`); **never restart or reconfigure shared Postgres or
   containers** — if the demo DB is unreachable, report it instead of "fixing"
   infrastructure.
3. **Security repros retained**: #1, #7, #10 fail closed in the suites (plan
   Final gate 4).
4. **Tenant-strategy tests** cover context tenant structs, attribute tenancy,
   and changeset-less notifications (plan Final gate 5 — the **A0/R0** items).
   MDL owns most of this via A0; the **changeset-less multitenant broadcast**
   coverage is ash_remote's, owned by **M8 via R0** (pass-6 review) — check both
   sides, not only A0.
5. **Semantic docs sweep** (second-review plan Final gate 6): MDL guide/runbook
   (sweeper behavior, auth park class, resolution idempotency, tenant strategy
   rules, deferred LOWs), ash_remote server manifest/auth notes, LocalOutbox
   sweeper + park classes, codegen manifest validation notes; L10's
   contradictions resolved against final behavior.
6. **First-plan handoff docs sweep** (its final gate 3 — named items):
   moduledocs changed by semantics — the write_through spec promoted to the
   moduledoc, classify/park classes, the upsert collision note, realtime field
   stripping; the guide's strategy section; the runbook's LocalOutbox section
   incl. the `:auth` park class. Verify these actually landed with the first
   plan's commits; sweep again if this tracker's work changed the semantics
   underneath them.
7. **Changelogs / decision logs** — update the log that **exists in each repo**
   (verified 2026-07-07): MDL has `CHANGELOG.md` only (already modified in the
   working tree — reconcile it with what actually lands); ash_remote has
   `DECISIONS.md` only. MDL `DECISIONS.md` and ash_remote `CHANGELOG.md` do
   **not** exist — create one only if that repo has genuine decision/release
   content to record; do not create empty files to satisfy the gate. (First-plan
   handoff gate 3 + second-review plan gate 6.)

## Prerequisite — checkpoint commit

The checkpoint commit is owned by the **[PRE](pre-checkpoint-commit.md)
preflight task** (step 0), not here — it must happen before any
retained-regression work, which is earlier than FINAL. FINAL only confirms it
happened.

- [ ] [PRE](pre-checkpoint-commit.md) is DONE — commits made, **or** a skip
      recorded **with the (a)/(b) durability plan** PRE requires (loop-6: a bare
      recorded skip is NOT sufficient, since it leaves Cat A commit-fragile;
      match PRE's and the index's wording)

## Done when

- [ ] All **other** open tasks in this tracker are DONE, WONTFIX, or in
      [deferred-follow-ups.md](deferred-follow-ups.md) (this excludes FINAL
      itself, which is necessarily still open while this box is checked)
- [ ] Gates 1–7 each checked off, or explicitly reported blocked with the
      blocker named
- [ ] The index closure claim re-verified against this list
