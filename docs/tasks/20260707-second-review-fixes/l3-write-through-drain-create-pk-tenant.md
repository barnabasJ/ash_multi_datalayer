# L3 — `write_through` inline drain misses creates; nil tenant on attribute-tenancy creates

- **Status**: IN PROGRESS — **tenant half DONE** (as planned, in the tenant-unit
  phase): `TenantKey`'s `attribute_value/2` now has an `%Ash.Changeset{}` clause
  reading `changeset.attributes` instead of the changeset struct's own top-level
  keys (always nil); repro confirms an attribute-tenancy create's tenant is now
  derived correctly; fails on unfixed code (confirmed). `drain_chain_inline`'s
  partition-key derivation also switched to `TenantKey.canonical/2`. The
  **create-PK drain half** (keying the inline drain on the effective PK, not
  `changeset.data`) is deferred to
  [H4](h4-write-through-drain-race-divergence.md), same function, per the
  index's execution order.
- **Severity**: Low (recreated row later deleted by stale destroy flush)
- **Repo**: MDL (ash_multi_datalayer)
- **Verification**: AGENT
- **Source**:
  [20260707 implementation review — L3](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Files**: `lib/ash_multi_datalayer/orchestrator/local_outbox/write.ex:55-59`;
  `tenant_key.ex` `attribute_value`
- **Depends on**: [B3](b3-tenant-from-filter-dead-code.md) (tenant half) —
  consume B3's canonical tenant function verbatim; do not add a local
  normalization
- **Related tasks**: [H4](h4-write-through-drain-race-divergence.md) (same
  function — the create-PK drain half),
  [H5](h5-localoutbox-nil-tenant-model.md)/[M2](m2-context-tenancy-raw-metadata-tenant.md)/[P4](p4-global-tenant-invalidation.md)
  (tenant unit)

## Defect

1. `write_through`'s inline drain keys on `changeset.data`'s PK — **nil for
   creates** — so a pending chain for a re-created client-generated PK isn't
   drained; the recreated row is later deleted by the stale `:destroy` flush.
2. `TenantKey.changeset(resource, changeset, changeset.data)` yields nil tenant
   for attribute-tenancy creates: `attribute_value` reads
   `Map.get(%Ash.Changeset{}, attr)` (always nil) — it should read
   `changeset.attributes`.

## Fix

Key the drain on the effective PK (changeset attributes/result for creates, not
`changeset.data`); make `attribute_value` read `changeset.attributes` for
creates. Fold the tenant half into the canonical tenant-key work (canonical
partition string — binding decision in the index).

## Done when

- [ ] Repro test: re-create with a client-generated PK over a pending `:destroy`
      chain drains the chain — fails on unfixed code by deleting the recreated
      row
- [ ] Attribute-tenancy create derives the correct tenant key **via B3's shared
      canonical function** — no local normalization
- [ ] `INTEGRATION=1 mix test` green in MDL
