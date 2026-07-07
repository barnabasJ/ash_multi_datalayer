# M1 — `{:ok, {:upsert_skipped, query, callback}}` crashes with `BadMapError`

- **Status**: OPEN
- **Severity**: Medium (crash on a legitimate upsert path)
- **Repo**: MDL (ash_multi_datalayer)
- **Verification**: VERIFIED
- **Source**:
  [20260707 implementation review — M1](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Original finding**: none — new finding
- **Files**: the crash path is in `enqueue_entries/7`:
  `lib/ash_multi_datalayer/orchestrator/local_outbox/write.ex:270`
  (`Snapshot.record_pk(resource, record)` → `Map.get` on the
  `{:upsert_skipped, …}` tuple) and `:273`
  (`TenantKey.changeset(resource, changeset, record)`) — `async_run/3`
  (~`:213-240`) merely forwards `record` into `enqueue_entries` (loop-6: point
  at :270/:273, not the forwarding range); also `write_dispatch.ex:82` +
  `tenant_key.ex:16,33-39`

## Defect

ash_sqlite/ash_postgres return `{:ok, {:upsert_skipped, query, callback}}` for
condition-skipped upserts (Ash core expects the data layer to surface it).
`WriteDispatch` handles the tuple, but:

1. `LocalOutbox.Write.async_run` passes it as `record` to `Snapshot.record_pk` →
   `Map.get({:upsert_skipped, ...}, pk)` → `BadMapError` inside
   `repo.transaction`.
2. For attribute-multitenant ProvenCoverage resources:
   `TenantKey.changeset(resource, changeset, {:upsert_skipped, ...})` →
   `attribute_value` → `Map.get(tuple, attr)` → `BadMapError` **after the
   authoritative write already ran**.

## Failure scenario

Any upsert with an `upsert_condition` that skips.

## Fix

Handle the `{:upsert_skipped, ...}` shape before snapshot/tenant extraction:
skip outbox entry creation / invalidation appropriately (a skipped upsert wrote
nothing) and return the tuple up the chain the way `WriteDispatch` does.

## Done when

- [ ] Repro test: upsert with a skipping `upsert_condition` through LocalOutbox
      and through an attribute-tenant ProvenCoverage resource — no crash; fails
      on unfixed code with `BadMapError`
- [ ] Skipped upserts don't enqueue a flush for a write that didn't happen
- [ ] `INTEGRATION=1 mix test` green in MDL
