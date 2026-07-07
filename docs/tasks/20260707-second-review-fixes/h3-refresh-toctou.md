# H3 — `refresh/3` TOCTOU vs the co-committed local write (#13)

- **Status**: OPEN
- **Severity**: High (lost update on the authority)
- **Repo**: MDL (ash_multi_datalayer)
- **Verification**: VERIFIED
- **Source**:
  [20260707 implementation review — H3](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Original finding**: #13 (also the #18-sibling `MatchError` noted below)
- **Plan ref**: Workstream A phase A5 item 4
- **Files**:
  `lib/ash_multi_datalayer/orchestrator/local_outbox/api.ex:341-372,477-492`
- **Related tasks**: [M5](m5-refresh-delete-reconciliation-not-atomic.md) (same
  code, plan-fidelity aspect), [M9](m9-discard-drop-chain-not-transactional.md)

## Defect

The `dirty?` check and `Backfill.upsert_record`/`reconcile_deletes` remain
separate, non-transactional steps; no co-commit `repo.transaction` or watermark
guard was added. Additionally `reconcile_deletes`'s local read still
hard-matches `{:ok, local_rows} =` — a `MatchError` on any error (the #18
sibling).

## Failure scenario

A user write commits between the dirty-check and the upsert → the stale remote
row overwrites the fresh local value (or a just-created row is deleted) while
the pending entry later flushes the user's value to the remote → the
authoritative local layer shows an **older state than the remote** (lost update
on the authority).

## Fix

Per plan A5 item 4 (and review W1): make `refresh/3` and delete reconciliation
atomic with the dirty check using the **real co-commit Ecto `repo.transaction`**
(resolve the repo via `co_commit_repo/3` as the async write path does) — NOT
`Ash.DataLayer.transaction`, which is a no-op on AshSqlite — or an equivalent
watermark guard the test proves closes the TOCTOU. Add `{:error, _}` handling to
the `reconcile_deletes` local read.

## Done when

- [ ] Repro test (plan A0 repro 9) proves the interleaving: a local write racing
      between dirty-check and refresh backfill is not clobbered — fails on
      unfixed code
- [ ] Test proves the mechanism works on AshSqlite (no reliance on
      `Ash.DataLayer.transaction` rolling back)
- [ ] `reconcile_deletes` returns a structured error instead of `MatchError`,
      and `delete_local_pk/5` (`api.ex:386-388`) returns `{:error, _}` instead
      of raising — same #18 no-crash-on-read-failure contract (pass-2 review §B)
- [ ] **`refresh/3` itself propagates the failure (pass-7 Medium)**: once the
      helpers stop raising and return `{:error, reason}`, `refresh/3` must
      return `{:error, reason}` — NOT bury it in a "successful"
      `%{deleted: {:error,     reason}}` map. (Loop-1 correction: on _current_
      code the helpers RAISE — `delete_local_pk/5` at `api.ex:387`, the hard
      `{:ok, _} =` match in `reconcile_deletes` at `:480` — so
      `%{deleted: {:error, _}}` does not exist yet; this bullet is a forward
      guard for the fixed code, not a description of current behavior.) Update
      the public spec/tests around the shape
- [ ] `INTEGRATION=1 mix test` green in MDL
