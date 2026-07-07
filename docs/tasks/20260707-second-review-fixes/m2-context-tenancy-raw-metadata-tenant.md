# M2 — External-change invalidation for `:context` tenancy uses the raw metadata tenant

- **Status**: DONE — both `notification_tenant/2` clauses (changeset and
  record-only) canonicalize via `TenantKey.canonical/2` before use as the
  `forget!/3` partition; `Invalidation.on_write/4`/`drop_all/2` ALSO
  canonicalize internally as a defensive choke point for any other caller. Repro
  test adapted to attribute-strategy (the fix is strategy-agnostic — same
  `notification_tenant/2` code path — building full context-tenancy Postgres
  schema infra was unnecessary): an inbound notification carrying a
  non-canonical (atom) tenant invalidates the exact partition a prior read
  recorded; fails on unfixed code (confirmed). `INTEGRATION=1 mix test` green
  (279).
- **Severity**: Medium (wrong-partition invalidation → permanent stale entry)
- **Repo**: MDL (ash_multi_datalayer)
- **Verification**: AGENT
- **Source**:
  [20260707 implementation review — M2](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Original findings**: #3 / A5 family
- **Files**: `lib/ash_multi_datalayer/tenant_key.ex:25` (`metadata_tenant`) via
  `proven_coverage.ex:198-200`
- **Depends on**: [B3](b3-tenant-from-filter-dead-code.md) — consume B3's
  canonical tenant function verbatim; do not add a local normalization
- **Related tasks**: [H5](h5-localoutbox-nil-tenant-model.md),
  [L3](l3-write-through-drain-create-pk-tenant.md),
  [P4](p4-global-tenant-invalidation.md) — the tenant unit

## Defect

Read-side coverage partitions and write-side `changeset.to_tenant` both use the
**converted** (`to_tenant`) tenant, but `record.__metadata__.tenant` is the
**raw** tenant. `notification_tenant/2`'s changeset-less clause uses
`TenantKey.record` → raw metadata tenant.

## Failure scenario

Context multitenancy where callers pass a struct/integer tenant (`%Org{id: 1}` →
`"org_1"`): coverage lives under `"org_1"`; a replayed external notification
calls `forget!(..., tenant: %Org{}|1)` → epoch bump, ledger drop, and physical
eviction land in the **wrong partition** → the `"org_1"` entry keeps serving the
pre-change row indefinitely (the notification was the only invalidation signal).
The same raw-vs-string mismatch disables the dirty-chain check in
`Api.handle_external_change`.

## Fix

Convert raw tenants through the resource's `Ash.ToTenant` before partition
lookup — the one shared function (with B3/H5) that maps any tenant
representation (struct, integer, string, converted) to the canonical **partition
string** (binding decision in the index), used by every
read/write/notification/outbox path.

## Done when

- [ ] Repro test (plan A0 repro 3, context half): context-strategy resource with
      an `Ash.ToTenant` struct — external notification invalidates the exact
      partition a prior read recorded; fails on unfixed code
- [ ] Dirty-chain check in `handle_external_change` works with struct tenants
- [ ] Uses B3's shared canonical tenant function — no local normalization
- [ ] `INTEGRATION=1 mix test` green in MDL
