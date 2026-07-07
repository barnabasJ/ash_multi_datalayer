# P4 — `global? true` multitenancy: invalidation never crosses tenant partitions

- **Status**: DONE — `Invalidation.on_write/4`/`drop_all/2` now sweep
  `sweep_partitions/2` (P4's own 1:many orchestration, gated on
  `Ash.Resource.Info.multitenancy_global?/1`): a tenant-scoped write also
  bumps/drops the unscoped partition; a genuinely unscoped write sweeps every
  partition currently in the ledger (new `Coverage.partitions/1`). Each
  individual partition key still comes from B3's `TenantKey.canonical/2` — only
  the "which partitions" orchestration is new. New
  `AshMultiDatalayer.Test.Tenancy.AttrPost` `global? true` fixture (none existed
  before) + repro (both directions: tenant-write invalidates a prior nil-tenant
  read, and vice versa); fails on unfixed code (confirmed).
  `INTEGRATION=1 mix test` green (279).
- **Severity**: Medium (stale global reads after tenant-scoped writes)
- **Repo**: MDL (ash_multi_datalayer)
- **Source**:
  [20260704 implementation review — M6](../../reviews/20260704-implementation-review.md)
  (added per
  [task-coverage review F2](../../reviews/20260707-second-review-fixes-task-coverage-review.md))
- **Files**: `lib/ash_multi_datalayer/coverage/invalidation.ex:61-73`;
  `write_dispatch.ex`
- **Depends on**: [B3](b3-tenant-from-filter-dead-code.md) — the "which
  partitions does this write touch" answer belongs in B3's canonical tenant
  function; consume it, do not add a local normalization
- **Related tasks**: tenant unit [H5](h5-localoutbox-nil-tenant-model.md) +
  [M2](m2-context-tenancy-raw-metadata-tenant.md) +
  [L3](l3-write-through-drain-create-pk-tenant.md)

## Defect

`on_write` scans only `Coverage.entries(resource, tenant)`. With
attribute-strategy multitenancy and `global? true`: a nil-tenant read
(legitimately spanning all tenants) records an entry under `:__global__`; a
tenant-T write later changes a matching row; `on_write(resource, T, ...)` never
touches the `:__global__` partition → the global entry keeps serving pre-write
rows. Mirror case for nil-tenant writes vs tenant-scoped entries.

## Fix

Conservative fix from the original review: tenant-scoped writes also sweep
`:__global__`; nil-tenant writes sweep all partitions. Verify against Ash
`global?` semantics before implementing.

**Scope split vs B3 (loop-2 review)**: B3's canonical function is **1:1**
(tenant representation → one partition key). P4's `global?` sweep is **1:many**
(a tenant-T write must touch partition T **and** `:__global__`). That
multi-partition **sweep-orchestration logic lives in P4**, not in B3's function.
Use B3's function to derive each individual partition key; "consume B3, don't
add a local normalization" means don't re-derive the canonical key — it does NOT
prohibit the sweep logic. Do not expect B3 to return partition _lists_.

## Done when

- [ ] Repro test: `global? true` resource — nil-tenant read, tenant-T write,
      re-read is not stale; and the mirror case — fails on unfixed code
- [ ] A multitenant test resource exists in the suite (original review noted
      there was none)
- [ ] Each individual partition key is derived via B3's shared canonical
      function; the 1:many sweep orchestration is P4's own logic
- [ ] `INTEGRATION=1 mix test` green in MDL
