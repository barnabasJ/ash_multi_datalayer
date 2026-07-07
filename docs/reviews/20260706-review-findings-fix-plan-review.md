# Review: 2026-07-06 review-findings fix plan

**Date**: 2026-07-06  
**Scope**: `docs/plans/20260706-review-findings-fix-plan.md`, checked against the cited whole-repo review and the relevant source paths in `ash_multi_datalayer` and sibling `../ash_remote`.

## Findings

- [critical] `docs/plans/20260706-review-findings-fix-plan.md:74` - `M-1` proposes dropping the parked chain before applying the resolution changeset, and explicitly accepts the apply-raises case losing the parked conflict. That contradicts the plan's own invariant at `docs/plans/20260706-review-findings-fix-plan.md:17`, which says a resolution verb must either converge or return an error with the parked chain intact. It also preserves the dangerous part of the current bug: error evidence can still be destroyed. The fix should avoid a broad pre-apply `drop_chain/1`; capture the old chain identity and either delete only those old entries after a successful resolution write, or perform a transaction/marker flow that restores or preserves the old chain if the write fails.

- [warning] `docs/plans/20260706-review-findings-fix-plan.md:81` - The `write_through/3` fix says to push a record "built from the changeset" before the local write. That is not equivalent to the existing propagation contract: `Backfill` documents that propagated records are loaded structs returned by a lower layer, because database/action-generated values exist only on the returned record (`lib/ash_multi_datalayer/backfill.ex:7`). A changeset-derived struct can miss generated PKs, defaults, calculations selected by the write path, or values normalized by actions. The plan needs to specify how the target-first write obtains the canonical record for create/update without relying on the local write's return, and it needs regression coverage for generated/defaulted fields.

- [warning] `docs/plans/20260706-review-findings-fix-plan.md:120` - The reconcile epoch fix says to bump the invalidation epoch before ghost eviction, but the current code records coverage after `reconcile/5` using the original `epoch0` (`lib/ash_multi_datalayer/orchestrator/proven_coverage.ex:716`). If reconcile bumps the epoch, the initiating read's own `Coverage.record/5` will see `:epoch_moved` and skip recording whenever ghosts were evicted. That may be an acceptable conservative tradeoff, but the plan does not say so and the A3 gate does not assert post-cleanup coverage behavior. Either document the intentional skip and test the next read records cleanly, or refresh the epoch after successful reconcile and make the safety argument explicit.

- [warning] `docs/plans/20260706-review-findings-fix-plan.md:207` - The realtime field-policy plan is under-specified. It says to derive a "field-policied attribute set" from `Ash.Resource.Info.field_policies/1` and strip those fields, but the implementation must strip the policy target fields, not fields referenced by policy conditions, and must apply the same stripping to both `"data"` and `"changed"`. The current source serializes `Decoder.write_fields(resource)` into `"data"` and independently builds `"changed"` from public changed attributes (`../ash_remote/lib/ash_remote/server/notifier.ex:75`, `../ash_remote/lib/ash_remote/server/notifier.ex:98`), so missing either path leaves an inconsistent or still-leaky payload.

- [warning] `docs/plans/20260706-review-findings-fix-plan.md:256` - The `ClientId` fix says to key by `{name, base_url}` and store in the connection registry instead of `:persistent_term`, but the HTTP request path currently has no connection name or registry in scope. `AshRemote.Transport.Req.headers/1` only receives `base_url` through `Config` and calls `ClientId.get(base_url)` (`../ash_remote/lib/ash_remote/transport/req.ex:59`). The plan must include how request construction gets the realtime connection identity, or keep a canonical per-base-url client id. Otherwise echo suppression will silently stop working or still collide across named supervisors.

- [suggestion] `docs/plans/20260706-review-findings-fix-plan.md:174` - The R-1 regression harness covers multitenant reads/writes, but the planned protocol change also threads tenant through `/rpc/validate` (`docs/plans/20260706-review-findings-fix-plan.md:193`). Add a validate-path tenant test so `Protocol.build_validate/1` and `Server.validate_action/2` do not regress independently from `/rpc/run`.

- [suggestion] `docs/plans/20260706-review-findings-fix-plan.md:141` - The stale-resource resolver fix for `String.to_existing_atom(entry.resource)` should explicitly avoid `Module.concat([input])` on persisted strings. The ash_remote review already identifies `Module.concat/1` as atom-minting on untrusted input; for LocalOutbox, use the configured resource set/string map rather than reconstructing arbitrary module names.

## What Looks Sound

- The plan correctly prioritizes reproduction-first tests before fixes, and the A0/B0 harnesses cover the highest-risk silent-divergence and exposure paths.
- The co-commit validation direction for M-4 is appropriate: LocalOutbox should reject configurations that cannot make the local write and outbox entry durable together.
- The R-2 resource-map direction is the right root fix for atom exhaustion in both RPC and realtime resolution paths.
- The B2 transport error work correctly identifies the seam that MDL's flush taxonomy will consume.

## Summary

1 critical, 4 warnings, 2 suggestions.

The plan is close, but `M-1` should be corrected before implementation because it violates the central resolution invariant the plan sets out to restore.
