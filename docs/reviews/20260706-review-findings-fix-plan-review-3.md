# Review: amended 2026-07-06 review-findings fix plan, round 3

**Date**: 2026-07-06  
**Scope**: updated `docs/plans/20260706-review-findings-fix-plan.md`, checked against the prior reviews and relevant source in `ash_multi_datalayer` and sibling `../ash_remote`.

## Findings

- [warning] `docs/plans/20260706-review-findings-fix-plan.md:136` - The M-2 force-back design is now directionally correct, but the wording is still easy to implement too broadly. It says to force materialized values back into the changeset "for every attribute the materialization filled," including PK and timestamps. On updates, `Ash.Changeset.apply_attributes/1` returns `changeset.data` with only `changeset.attributes` overlaid (`deps/ash/lib/ash/changeset/changeset.ex:7566`), so unloaded fields remain `%Ash.NotLoaded{}` and untouched nullable fields may remain `nil`. Forcing those into the changeset can either fail casting or overwrite/suppress local-layer/database defaults. Tighten the checklist to force back only values that are actually loaded/materialized and intended to be identical on both sides: changed attributes plus Ash-level defaults needed for the target push, excluding `%Ash.NotLoaded{}` and non-Ash DB-generated fields. If non-PK DB-generated fields are unsupported for write_through creates, say that explicitly rather than guarding only nil PKs.

- [suggestion] `docs/plans/20260706-review-findings-fix-plan.md:122` - The rebase cleanup failure posture is good, but the error shape could be more actionable. `{:error, :rebase_cleanup_failed}` alone cannot carry the parked entry IDs, resource, target, or underlying reason that an operator needs to run the documented recovery (`discard/1` on the parked head). Specify a structured error or tuple payload that includes the original cause and the still-parked head/chain identity.

## Resolved Since Round 2

- The previous `write_through` double-default warning is addressed: the plan now materializes once and forces the values back before the local write.
- The previous `rebase` cleanup warning is addressed: cleanup now runs in one outbox-repo transaction with a defined blocked-but-recoverable failure posture.
- The R-2 persistent-term key suggestion is addressed with per-site keys.
- The A2 migration note is corrected: outbox attributes are transformer-injected, so `:auth` arrives via library upgrade and recompile, not generator rerun.

## Summary

0 critical, 1 warning, 1 suggestion.

The plan is implementation-ready once the M-2 force-back wording is tightened to avoid forcing unloaded or DB-generated values into the local write.
