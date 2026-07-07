# B7 — Resolution-verb guard inverted for `:synced` entries (#17)

- **Status**: OPEN
- **Severity**: Blocker (re-applies already-applied writes)
- **Repo**: MDL (ash_multi_datalayer)
- **Verification**: VERIFIED
- **Source**:
  [20260707 implementation review — B7](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Original finding**: #17
- **Plan ref**: Workstream A phase A5 item 9
- **Files**: `lib/ash_multi_datalayer/orchestrator/local_outbox/api.ex:603-621`
  (`ensure_resolvable_head/1`); call sites retry `:111`, discard `:131`, force
  `:191`, rebase `:238`

## Defect

`ensure_resolvable_head/1`'s `cond` returns `:ok` for `entry.state == :synced`
(falls into the `with` body), so retry, discard, force, and rebase all
**proceed** on synced entries. No re-fetch before applying; no idempotent
conversion of not-found/stale destroy.

```elixir
cond do
  entry.state == :synced -> :ok            # <- falls INTO the with body
  entry.state != :parked -> {:error, :not_parked}
  ...
end
```

## Failure scenario

`retry(entry)` on a stale handle to a now-synced entry → re-pends →
`Enqueue.flush` → the already-applied write is pushed again (a destroy
re-deletes a re-created row; per-PK FIFO can invert). `force` on a synced entry
re-pushes then destroys.

## Fix

Per plan A5 item 9: only **parked chain heads** may be retried, forced,
discarded, or rebased. Re-fetch the entry before applying; convert
not-found/stale-destroy into idempotent `:ok` where the desired final state is
already true. **Pick ONE contract for a `:synced` stale handle (loop-1 review):
an idempotent no-op success** — the verbs must not fall through to the action.
(Non-_head_/non-_parked_ entries are a separate case: those are rejected with a
typed error. `:synced` head = no-op success; not-head/not-parked = typed error.)

## Done when

- [ ] Repro test (plan A0 repro 13): each verb called with a stale handle to a
      now-`:synced` entry is a no-op success. **Failure modes differ by verb —
      pick the entry `op` that actually fails unfixed (loop-1 + loop-2
      review)**: - `retry`/`force`: fail unfixed by **re-pushing** to the
      target. - `discard` of a **non-`:create`** entry
      (`op: :update`/`:destroy`): fails unfixed by **destroying the synced
      entry + `kick_next`** (`api.ex:144`). Use a non-create entry —
      **create-discard is ALREADY a no-op** on unfixed code (`record_chain` at
      `api.ex:518-528` filters `state != :synced`, so the synced entry is
      excluded → nothing destroyed), so a create entry would falsely "pass". -
      `rebase`: fails unfixed regardless of `op` — it applies the resolution
      changeset (a real mutation) even when `record_chain` returns `[]`. Assert
      the per-verb effect, not just "a target push happened"
- [ ] Verbs reject non-parked, non-head entries with typed errors
- [ ] Duplicate/repeated calls are idempotent
- [ ] `INTEGRATION=1 mix test` (incl. `local_outbox_resolution_test.exs`) green
