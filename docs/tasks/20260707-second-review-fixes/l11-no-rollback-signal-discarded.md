# L11 — `{:error, :no_rollback, _}` normalized away, discarding the layer's signal

- **Status**: DONE — audited all five sites (the task's list, re-verified
  against current source — line numbers had drifted but all five modules were
  current):

  **Preserve (result reaches Ash's transaction machinery)**:
  - `write_dispatch.ex`'s authoritative-write `case` in `dispatch/4` — the
    `normalize_result/1` call here was removed entirely; a
    `{:error, :no_rollback, _} = error -> error` clause added instead.
  - `local_outbox/write.ex`'s `normalize/1` (feeds `push_all_targets/5` →
    `write_through/3`'s return) and `normalize_upsert/1` (feeds
    `local_write/4`'s `{:upsert, ...}` clause → both `write_through/3` and
    `async_run/3`'s co-commit transaction) — both preserve the 3-tuple now.
  - `backfill.ex`'s `destroy_record/4` and `upsert_record/4` — the shared,
    single source-of-truth wrappers every other site's `Backfill` call goes
    through — now preserve the 3-tuple; each _caller_ decides whether it's safe
    to strip again.
  - Two follow-on `CaseClauseError` sites the 3-tuple newly reaches were found
    and fixed while wiring this through: `async_run/3`'s _inner_
    `case local_write(...)` (a second match needed, not just the outer
    `case committed`) and `in_transaction/2` was audited and found already
    correct by construction (its 2-tuple-only
    `{:error, error} -> repo.rollback(error)` pattern simply not matching a
    3-tuple **is** the desired "don't roll back" behavior).

  **Normalize, decision recorded (result never reaches Ash)**:
  - `write_dispatch.ex`'s `propagate/6` (secondary-layer propagation,
    `Enum.each`-discarded, log/telemetry-only).
  - `proven_coverage.ex`'s `evict_ghost/4` (reconcile-pass ghost eviction,
    log-only) and `coverage/invalidation.ex`'s `evict_physical_row/3`
    (physical-row eviction, log-only) — both needed a new matching clause to
    avoid crashing on the now-possible 3-tuple from `destroy_record/4`, kept as
    a normalize-and-log.
  - `local_outbox/api.ex`'s `normalize/1` (discard_local/1, rebase/2, discard/1
    — direct resolution-API calls, never routed through Ash) and
    `normalize_backfill/1` (boot_hydrate/resume_sync background tasks, which
    already `raise` on any failure shape regardless).

  `FailableLayer.guard/2` gained a `:no_rollback` fail-spec (test
  infrastructure) to construct a deterministic repro. 1 test: arms
  `FailableLocalWidget`'s local (authoritative) layer to `:no_rollback` and
  calls `Ash.DataLayer.upsert/4` directly, asserting the 3-tuple reaches the
  caller unstripped — confirmed via stash to return the stripped 2-tuple on
  unfixed code. Internal classify/park paths (destroy_result's already-absent
  check, etc.) still handle the normalized shape where applicable, verified by
  the full suite staying green throughout. `INTEGRATION=1 mix test` green (324,
  up from 323).

- **Severity**: Low (contract deviation, narrow impact)
- **Repo**: MDL (ash_multi_datalayer)
- **Verification**: AGENT
- **Source**:
  [20260707 implementation review — L11](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Files**: **five** normalizer sites, not three (pass-7 Medium):
  `lib/ash_multi_datalayer/write_dispatch.ex:162`,
  `lib/ash_multi_datalayer/orchestrator/local_outbox/write.ex:208,314`, and
  `lib/ash_multi_datalayer/backfill.ex:103-108,125-126`

## Defect

`{:error, :no_rollback, reason}` is normalized to `{:error, reason}` at MDL
boundaries — which fixed the `CaseClauseError` (plan A2 item 2) but discards the
layer's no-rollback signal. Ash then rolls back a transaction the layer said to
preserve.

## Fix

Where the error propagates back to Ash's transaction machinery, preserve the
3-tuple (normalize only for MDL-internal pattern matching / classification).
Audit **all five** call sites for which consumer each feeds — the two
`backfill.ex` normalizers may be intentionally internal, but that decision must
be made and recorded, not left implicit.

## Done when

- [ ] Test: a layer returning `{:error, :no_rollback, reason}` inside an Ash
      transaction does not get rolled back by Ash
- [ ] Each of the five normalizers either preserves the 3-tuple when it
      propagates back to Ash, or has a recorded reason it is safe to normalize
      at that boundary (incl. the two `backfill.ex` sites)
- [ ] Internal classify/park paths still handle the normalized shape
- [ ] `INTEGRATION=1 mix test` green in MDL
