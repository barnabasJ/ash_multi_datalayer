# H4 — `write_through` drain race and post-target-push divergence (#14, #15)

- **Status**: OPEN
- **Severity**: High (target regression; silent divergence)
- **Repo**: MDL (ash_multi_datalayer)
- **Verification**: VERIFIED
- **Source**:
  [20260707 implementation review — H4](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Original findings**: #14, #15
- **Plan ref**: Workstream A phase A5 items 5, 6
- **Files**: `lib/ash_multi_datalayer/orchestrator/local_outbox/write.ex:52-98` (`drain_chain_inline` proper begins at `:67`)
- **Related task**: [L3](l3-write-through-drain-create-pk-tenant.md) (drain
  keying bugs in the same function)

## Defect

1. **#14**: `drain_chain_inline` reads-and-pushes with no per-PK lock, no queue
   pause, and no worker re-check of entry existence before push. An in-flight
   Oban worker can upsert V1 over write_through's V2 after the drain destroyed
   the entry.
2. **#15**: after `push_all_targets` succeeds, a `local_write` failure just
   returns the error — no pre-image compensation, no divergence record. Targets
   hold V2, the caller is told "failed", and a later refresh materializes the
   "failed" write.

## Fix

Per plan A5 items 5–6:

- Prevent the inline drain from racing an already-running worker: per-PK
  lock/queue pause, or the worker re-reads entry existence and state immediately
  before pushing.
- On target-success/local-failure: compensate by re-pushing the pre-image, or
  persist a divergence record operators can resolve. Never silently return an
  ordinary failure while targets hold the new value.

## Done when

- [ ] Repro test (plan A0 repro 10) proves the interleaving: stale in-flight
      flush cannot regress the target after inline drain — fails on unfixed code
- [ ] Repro test (plan A0 repro 11): target divergence after local failure is
      compensated or durably recorded — fails on unfixed code
- [ ] `INTEGRATION=1 mix test` (incl. `local_outbox*`) green in MDL
