# M9 — `discard`/`drop_chain` not inside the co-commit transaction (#16 partial)

- **Status**: OPEN
- **Severity**: Medium (atomicity claim unmet)
- **Repo**: MDL (ash_multi_datalayer)
- **Verification**: AGENT
- **Source**:
  [20260707 implementation review — M9](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Original finding**: #16 (partially fixed)
- **Plan ref**: Workstream A phase A5 item 7
- **Files**:
  `lib/ash_multi_datalayer/orchestrator/local_outbox/api.ex:130-152,531-536`

## Defect

The behavior half of #16 landed: `discard` of a non-create head kicks the next
entry, and create-discard/`drop_chain` destroy newest-first. But neither runs
inside the co-commit `repo.transaction` the plan requires — only
`destroy_captured_chain` got `transaction!`. A mid-drop crash still leaves a
partially destroyed chain (newest-first fails in the safer direction, but the
atomicity claim is unmet).

**Rebase cleanup (pass-2 review F4)**: plan A5 item 8 folded the
rebase-transaction LOW into the same W1 requirement. **Loop-1 review
(verified)**: `transaction!/2` (`api.ex:623-627`) ALREADY uses the real Ecto
`repo.transaction` (`repo.transaction(fn -> fun.() end)`), and
`destroy_captured_chain` already runs inside `transaction!` — so rebase cleanup
is NOT defective. The "verify which transaction" step short-circuits: it's
already correct. The actual work is below.

## Fix

The real work is wrapping the **two paths that are NOT yet transactional** —
`drop_chain/1` (`api.ex:530-537`) and the **create-discard branch of
`discard/1`** (`api.ex:137-140`) — in the same `transaction!/2` helper that
`destroy_captured_chain` already uses (real co-commit Ecto `repo.transaction`,
not `Ash.DataLayer.transaction`). The accepted review disposition W1 requires
the real co-commit transaction; a documented partial-cleanup posture is **not**
an acceptable completion path — reopening that decision means re-litigating W1
with the user, not a checklist choice.

## Done when

- [ ] SQLite-backed test proves create-discard and `drop_chain` destroys are
      atomic via the real co-commit `repo.transaction` (the two paths not yet
      wrapped)
- [ ] Rebase cleanup (`destroy_captured_chain` via `transaction!`) already uses
      the real co-commit `repo.transaction` — retain a regression asserting so
      (plan A5 item 8 / W1); no new fix needed there
- [ ] `INTEGRATION=1 mix test` green in MDL
