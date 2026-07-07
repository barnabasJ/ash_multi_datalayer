# Review: amended 2026-07-06 review-findings fix plan, round 4

**Date**: 2026-07-06  
**Scope**: updated `docs/plans/20260706-review-findings-fix-plan.md`, checked against prior reviews and relevant source in `ash_multi_datalayer`, vendored Ash, and sibling `../ash_remote`.

## Findings

- [warning] `docs/plans/20260706-review-findings-fix-plan.md:170` - The M-2 materialization design dropped force-back correctly, but it still does not say how to avoid pushing unloaded fields to targets. `Ash.Changeset.apply_attributes/1` returns `changeset.data` overlaid with changed/defaulted attributes; on an update from a partially loaded record, untouched fields can remain `%Ash.NotLoaded{}`. The planned target push goes through `Target.upsert/4`, which calls `Backfill.upsert_record/4` without a `:fields` option (`lib/ash_multi_datalayer/orchestrator/local_outbox/target.ex:14`), and `Backfill.upsert_record/4` defaults to all resource attributes (`lib/ash_multi_datalayer/backfill.ex:53`, `lib/ash_multi_datalayer/backfill.ex:110`). That can make write_through updates fail before the local write, or worse if a target accepts bad values. Specify that the outbound write_through record is pushed with only loaded/materialized fields plus primary key, excluding `%Ash.NotLoaded{}`; add a regression for a write_through update from a partially selected record.

- [suggestion] `docs/plans/20260706-review-findings-fix-plan.md:109` - A0 now adds boot hydration and `chain_position` blocked coverage, but these are described as gap-filling and may pass today. That is fine, but the phase title still says "all failing before fixes". Adjust the heading or gate wording so implementers do not spend time trying to force passing gap-fill tests to fail.

## Resolved Since Round 3

- The broad M-2 force-back is removed; the plan now relies on Ash's pre-data-layer lazy default materialization and keeps the lazy-default test as arbitration.
- The rebase cleanup error now carries structured recovery context.
- `discard/1` idempotency is now an A1 deliverable with double-discard coverage.
- Validate-path actor/tenant handling, `connect_params` semantics, `:blocked` wording, and the R-10 `:applicable` decision are now explicit.

## Summary

0 critical, 1 warning, 1 suggestion.

The plan is close to implementation-ready. Tighten M-2 so target pushes never include unloaded fields, and the remaining issue is a wording cleanup.
