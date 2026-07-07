# M4 — `discard_local/1` destroys a freshly re-read chain and skips the head guard

- **Status**: OPEN
- **Severity**: Medium (silent divergence — M-1-class)
- **Repo**: MDL (ash_multi_datalayer)
- **Verification**: AGENT
- **Source**:
  [20260707 implementation review — M4](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Original findings**: M-1-class recurrence; #18 (remote-gone branch)
- **Files**:
  `lib/ash_multi_datalayer/orchestrator/local_outbox/api.ex:160-186,530-537`

## Defect

`rebase/2` was fixed to capture the chain _before_ applying; `discard_local/1`
was not — it still upserts the remote row, then calls `drop_chain(entry)`, which
**re-reads `record_chain` at destroy time**. It also lacks
`ensure_resolvable_head`, and its remote-gone branch builds
`backfill_opts(host)` without the entry's tenant.

## Failure scenario

An ordinary `Write.run` on the same record lands between the local upsert and
`drop_chain` → the new `:pending` entry is destroyed → the user's write is
durable locally but its replication entry is gone → silent divergence (no park,
no error).

## Fix

Mirror the rebase fix: capture chain entry IDs before applying and destroy only
the captured set; add the `ensure_resolvable_head` guard (see
[B7](b7-resolution-verb-synced-guard.md) for the corrected guard semantics);
thread `entry.tenant` into the remote-gone `backfill_opts`.

## Done when

- [ ] Repro test proves the interleaving: a concurrent write between upsert and
      drop_chain survives with its pending entry intact — fails on unfixed code
- [ ] `discard_local` on non-parked/non-head entries is rejected
- [ ] Remote-gone branch carries the entry tenant
- [ ] Retained regression (#18 half): `discard_local/1` returns a structured
      error when the target read (`Target.read_pk`) fails — no raise/crash
      (pass-3a review F2; owned here, or explicitly by an A0 harness test named
      before this task closes)
- [ ] `INTEGRATION=1 mix test` (incl. resolution tests) green in MDL
