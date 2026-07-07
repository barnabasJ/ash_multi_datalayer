# M5 — `refresh` / delete reconciliation not atomic with the dirty check (plan fidelity)

- **Status**: OPEN — **subsumed by [H3](h3-refresh-toctou.md)** (pass-3b review
  §B): closes automatically when H3 closes; do not work independently. Kept as
  the plan-fidelity breadcrumb for A5 item 4 / W1.
- **Severity**: Medium (plan-mandated mechanism absent)
- **Repo**: MDL (ash_multi_datalayer)
- **Verification**: VERIFIED
- **Source**:
  [20260707 implementation review — M5](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Original finding**: #13 (overlaps [H3](h3-refresh-toctou.md))
- **Plan ref**: Workstream A phase A5 item 4; review disposition W1
- **Files**:
  `lib/ash_multi_datalayer/orchestrator/local_outbox/api.ex:341-372,477-492`

## Defect

Overlaps H3; tracked separately because the plan **explicitly required** the
real co-commit `repo.transaction` (not `Ash.DataLayer.transaction`, which is a
no-op on AshSqlite) or a proven watermark guard on the refresh path. Neither is
present.

## Fix / Done when

Resolved by implementing [H3](h3-refresh-toctou.md) with the plan's mechanism.
Close this task when H3's test suite includes an explicit assertion that the
refresh path's atomicity does **not** rely on `Ash.DataLayer.transaction`
rolling back on AshSqlite (per plan A5 verify item 3).

- [ ] H3 implemented with the real co-commit repo transaction or proven
      watermark guard
- [ ] SQLite-backed test asserts the documented atomicity posture
- [ ] `INTEGRATION=1 mix test` green in MDL
