# Review: amended 2026-07-06 review-findings fix plan

**Date**: 2026-07-06  
**Scope**: updated `docs/plans/20260706-review-findings-fix-plan.md`, checked against the prior plan reviews and the relevant source in `ash_multi_datalayer` and sibling `../ash_remote`.

## Findings

- [warning] `docs/plans/20260706-review-findings-fix-plan.md:108` - The amended `write_through/3` materialization still has a correctness hole. The plan says to build the outbound record with `Ash.Changeset.apply_attributes/2`, then later run `local_write` with the original changeset. In Ash, `apply_attributes/2` calls `set_defaults/3` on a local copy and returns a record; it does not mutate the original changeset (`deps/ash/lib/ash/changeset/changeset.ex:7566`). Local data layers also call `apply_attributes/2` during create (`deps/ash/lib/ash/data_layer/ets/ets.ex:1700`). That means UUID defaults, timestamps, or other lazy defaults can be evaluated once for the target push and again for the local commit, producing different records. The A0 materialization test should catch this, but the plan should specify the actual fix: materialize once and force those values back into the changeset before both target push and local write, or otherwise guarantee the same record is used on both sides.

- [warning] `docs/plans/20260706-review-findings-fix-plan.md:94` - The corrected `rebase/2` design handles apply failures but not cleanup failures after the resolution write succeeds. The sequence is apply changeset, destroy captured old entries, then kick. If destroying one of the captured old entries raises or partially succeeds, the caller can receive an error after the local resolution and fresh outbox entries were already committed, while the parked chain may be partially removed or still blocking the fresh chain. That violates the same "ok converges / error leaves evidence intact" invariant the amendment fixed for apply failures. The plan should define the failure posture for captured-entry destruction, preferably by making old-entry cleanup transactional/idempotent or by treating cleanup failure as a recoverable parked-chain state with an explicit retry path.

- [suggestion] `docs/plans/20260706-review-findings-fix-plan.md:269` - R-2 now correctly notes that RPC and channel resource resolution use different resource sets, but the cache-key text still names a single key: `{AshRemote.Server, :resource_map, otp_app}`. If implementation uses per-site maps, the key needs to include the site (`:rpc` vs `:channel`) or the cached value needs to be a tagged structure containing both maps. As written, it is easy to accidentally have one resolver overwrite or reuse the other's map.

- [suggestion] `docs/plans/20260706-review-findings-fix-plan.md:116` - The `write_through` limitation text has a Markdown typo: ``{:error, *}`naming`` and then ``return`{:error, \_}``. Clean it up before this plan is used as an implementation checklist.

## Resolved From Prior Review

- The previous critical M-1 issue is fixed in the plan: it now captures old entry IDs, applies the changeset, destroys only captured entries, and preserves the parked chain when apply fails.
- The previous M-3 epoch-only design issue is fixed: the plan now requires on-write-style entry dropping, not just an epoch bump.
- The realtime field-policy, validate-tenant, LocalOutbox resource-resolution, and ClientId review comments were incorporated.

## Summary

0 critical, 2 warnings, 2 suggestions.

The amended plan is substantially stronger. The remaining blocking risk is the `write_through` materialization design: it needs to ensure defaults are evaluated once and shared by the target push and local commit.
