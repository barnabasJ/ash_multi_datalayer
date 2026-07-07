# L11 — `{:error, :no_rollback, _}` normalized away, discarding the layer's signal

- **Status**: OPEN
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
