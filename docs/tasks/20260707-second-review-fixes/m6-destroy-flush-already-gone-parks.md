# M6 — Destroy-flush of an already-gone row parks as `:rejected`

- **Status**: OPEN
- **Severity**: Medium (blocks PK chain; demands operator intervention)
- **Repo**: MDL (ash_multi_datalayer)
- **Verification**: AGENT
- **Source**:
  [20260707 implementation review — M6](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Plan ref**: Workstream A phase A5 item 11 (remote `not_found` on destroy =
  idempotent success)
- **Files**: `lib/ash_multi_datalayer/backfill.ex:86-109` (`destroy_record/4`);
  `flush.ex` `classify`

## Defect

`destroy_record` documents "already absent is a success" but returns the layer's
error (`%Ash.Error.Changes.StaleRecord{}` on zero-row deletes; a
NotFound/Invalid-class error from remote layers). Nothing maps "absent" → `:ok`.

## Failure scenario

A `:destroy` flush succeeds but the worker crashes before committing `:synced`;
the retry's destroy fails (row gone) → `classify(%{class: :invalid})` →
`:rejected` → the entry parks and blocks the per-PK chain, demanding operator
`discard/1` for a destroy that already took effect.

## Fix

Map "row already absent" (StaleRecord on zero-row delete, remote NotFound) to
`:ok` in `destroy_record` (or classify it as idempotent success in the flush
path), per plan A5 item 11 and the function's own documentation.

## Done when

- [ ] Repro test: destroy flush retried after the row is already gone marks
      `:synced` — fails on unfixed code by parking `:rejected`. **Cover BOTH
      error classes (loop-1 review)**: the SQLite-local `%StaleRecord{}` on a
      zero-row delete AND a **remote-layer NotFound-class** error — the MDL
      suite runs on SQLite, so a `StaleRecord`-only fix would satisfy a single
      repro while remote NotFound still parks `:rejected`
- [ ] Genuine invalid destroys (e.g. validation failure) still park
- [ ] `INTEGRATION=1 mix test` green in MDL
