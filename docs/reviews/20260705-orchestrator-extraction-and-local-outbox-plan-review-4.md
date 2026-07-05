# Review 4: Orchestrator Extraction + LocalOutbox Plan (revision 4)

**Metadata:**

- Type: review
- Status: complete
- Created: 2026-07-05
- Subject:
  [docs/plans/orchestrator-extraction-and-local-outbox-plan.md](../plans/orchestrator-extraction-and-local-outbox-plan.md)
  (revision incorporating review-3 V1–V4 and pass-4 P1–P3)
- Prior reviews in this series:
  [review 1](./20260705-orchestrator-extraction-and-local-outbox-plan-review.md),
  [review 2](./20260705-orchestrator-extraction-and-local-outbox-plan-review-2.md),
  [review 3](./20260705-orchestrator-extraction-and-local-outbox-plan-review-3.md)
- Method: full re-read; incorporation check of review-3 V1–V4 and
  [pass 4](./20260705-orchestrator-extraction-and-local-outbox-plan-review-pass4.md)'s
  P1–P3; direct verification of the one new cross-doc claim (the sync-state ADR
  footnote) and the working tree.

## Verdict

**Converged. The plan is ready to execute Phase 1.** This revision cleanly
absorbs both remaining review streams — pass-4's P1 (the fourth enqueue site)
landed as the "one enqueue helper, four call sites" enumeration in Phase 3 with
the Phase 4 flush-body cross-reference exactly as recommended, and review-3's V1
process-establishment gaps are closed with the right mechanisms (plug/hook sets
both dynamic repo and Oban name for caller processes; `job.conf.name` as the
flush body's first act for workers; `child_specs/1` config for strategy
processes). No new substantive findings. What remains is bookkeeping.

## Incorporation check

- **Pass-4 P1** (chain-continuation + retry re-trigger enqueues): **closed.**
  Phase 3 enumerates all four sites through the MDL-owned helper, flags the last
  two as the non-obvious library-internal ones, and adds the uniformity
  rationale (telemetry/unique-args even single-instance); Phase 4's flush
  deliverable says "through the Phase 3 MDL enqueue helper, never
  `AshOban.run_trigger/3`", covering `retry/1` too. Matches P1's recommended
  edit in full.
- **Pass-4 P2** (sweep worker vs the ADR's "no scheduler" claim): **closed, on
  both sides.** Phase 3 carries the ADR-qualification paragraph, and the
  sync-state ADR itself now footnotes the named exception at its "no queue, no
  drainer, no scheduler" line — verified in the ADR file, including the "holds
  unqualified only for single-default-instance deployments" scoping.
- **Pass-4 P3** (unique-dedup under MDL-owned insertion): **closed.** Phase 2
  item 11 now asserts it, with the honest "rides the worker struct, _should_
  carry it; prove it" framing — the right register for a spike item.
- **Review-3 V1**: **closed** (see verdict; Phase 2 item 11 also gained the
  worker-under-instance-B assertion resolved via `job.conf.name`).
- **Review-3 V2**: **closed.** The ~97 count is re-attributed to pass-3 R1 with
  B2's actual history stated; the "ADR's stale ~126" phrasing is gone; the
  lock-branch parenthetical now reads "demanded by pass-3 R3 (which was
  neutral...), direction per N10".
- **Review-3 V3**: **closed.** `2aca728` is in the commit chain; the
  count-method note (mix test output, grep undercounts parameterized tests) is
  in the facts.
- **Review-3 V4**: **NOT addressed.**
  `example/todo_client/lib/todo_client/live.ex` still carries the uncommitted
  modification. Housekeeping, not a plan defect — but it was the one pre-branch
  action item, and it's still pending. Commit or drop it before Phase 1 branches
  from `b290e0d`.

## Remaining nits

### W1 (bookkeeping) — the "Reviewed (all incorporated)" metadata list is stale

It stops at review 2. The body now cites review-3 (V1, V3) and pass-4 (P1–P3) in
six places, and both docs exist in `docs/reviews/` — add them to the metadata
list (review 3 V1–V4, pass 4 P1–P3) so the plan's own provenance claim stays
true. Given V4 is unresolved, either address it or scope the claim ("all
incorporated; V4 pending pre-branch").

### W2 (wording nano-nit) — the sweeper's instance resolution is implied, not stated

Phase 3's resolution sentence assigns caller-side site (1) to the plug/hook and
worker-side sites (3, 4) to `job.conf.name`, leaving site (2) — the sweep worker
— unassigned. It resolves the same way as (3, 4): it runs as a cron-inserted job
under instance B, so its `job.conf.name` _is_ B. One word ("worker-side sites
(2, 3, 4)") closes the enumeration.

## Bottom line

Four review rounds in this series (plus the parallel pass series) have gone from
two major architectural findings (the co-commit predicate, the ash_oban
named-instance gap) to a stale metadata list and a one-word enumeration fix. The
verification trail is complete: every load-bearing third-party claim in the
facts section has been checked against package sources or the repo during these
reviews, and the remaining unknowns are exactly where the plan puts them — Phase
2's spike items, each with a recorded fallback path. Execute.

---

**Last Updated**: 2026-07-05
