# Review: the 2026-07-06 review-findings fix plan (pass 5 / round 4)

**Date**: 2026-07-06 **Input**: the plan after its round-3 amendments (now seven
passes across three rounds), re-verified against source. **Verdict**:
implementation-ready, no criticals, no warnings. Round 3 adopted my pass-4 W1
(dropped the force-back) and — correctly — overrode my pass-4 claim that
`discard/1` idempotency already holds; it does not, and I verified that below.
Every round-3 amendment I could check is sound. There is nothing left that
blocks implementation; one optional guard-widening is noted at suggestion level.

As always, claims are verified against source, not the plan's restatement.

---

## Round-3 amendments — confirmed sound (verified)

### `discard/1` non-idempotency (round-3 W3) — overrides my pass-4 claim; round 3 was right

In pass 4 I wrote that "destroy-by-ID is idempotent … recovery re-derives the
chain." That was wrong: I generalized from the `:create` branch to the whole
function. Re-reading `api.ex:118`: the `:create` branch re-derives via
`record_chain(entry)` (idempotent-ish), but the **non-create** branch
(`api.ex:131`) calls `Ash.destroy!(entry, …)` directly on the passed struct — a
second call, or one racing a flush, raises on the already-destroyed record.
Round-3 W3 caught this; making `discard/1` idempotent (not-found/stale →
already-discarded) an A1 deliverable, with the double-discard covered in the
cleanup-failure test, is the correct fix. My pass-4 assertion is withdrawn.

### Force-back dropped (pass-4 W1, adopted) — A1-2 now clean
A1-2 materializes via `apply_attributes(changeset)`, pushes that record, and runs
the **original changeset unchanged** for the local write — relying on the
pipeline's pre-materialized defaults and `set_defaults`'s `changing_attribute?`
idempotency (re-verified: `create.ex:277`, `changeset.ex:4084/4142/4177`,
`changing_attribute?` at `:6423`). No values forced back, so no risk of pushing
`%Ash.NotLoaded{}`/untouched-nil into an update. The A0-2 lazy-default test
remains as the arbitration gate. Correct.

### create-time atomics guard (round-3 W2)
ETS consumes `changeset.create_atomics` (`ets.ex:1710`, `apply_atomics` matches
`%{create_atomics: …}`), distinct from `changeset.atomics`. A guard on `atomics`
alone would pass every create-time atomic — exactly what `apply_attributes` is
blind to. A1-2's "check both" is right.

### A0-3 harness guidance (round-3 S1) — verified the park lands on the reconcile scan
`BlockingLayer` injects `maybe_park/1` **only into `run_query/2`**
(`blocking_layer.ex:47`); write callbacks are forwarded without parking
(`:54`). So on a full-miss path, the sequence is source fetch (source layer) →
backfill writes (cache layer, **not** `run_query`, don't consume the arm) →
reconcile's `Delegate.run_on_layer` (cache layer `run_query`, **the first one
after arming** → parks). Arming the wrapped cache layer and driving a full miss
is exactly right; the prior "block at the source fetch" wording would have
aborted at `maybe_backfill`'s `epoch_moved?` guard. Sound.

### B2-3 denied-set semantics (round-3 S5)
`connect_params` is evaluated **once in `init/1`** (`connection.ex:33`) and
stored as `:join_params` (`:39`); `handle_connect` re-joins with the same
`socket.assigns.join_params` (`:57`), never re-evaluating. So "clear on
connect_params change" is unobservable within one process — the set is process
state that resets with the socket, and a fresh token arrives only via a new
process (empty set anyway). The misleading "evaluated per connect" comment
(`connection.ex:29`, `:149`) is correctly slated for fixing. Sound.

### A1-1 cleanup transaction + repo coupling (round-3 W4) and structured error
The `Ash.DataLayer.transaction(outbox, …)` wrap around the `Ash.destroy!` calls
is feasible (the outbox is `AshSqlite`) and correctly conditioned on A1-3's repo
requirement, with parked-head-last destroy order as the repo-less fallback
(verified reasoning: the parked head is what blocks the fresh chain, so
destroying it last preserves the blocker on partial failure). The cleanup error
now carries cause + parked head/chain identity — the right shape for an operator
recovery. Sound.

### Other round-3 items
`validate_action/3` + the router call-site as one joint edit (S3), `:applicable`
deletion committed now that `Gen`'s output is known (S4), the `:blocked`-is-
computed correction (S2), M-12 disposition with A0-7/A0-8 (W5), and the
moduledoc/clause-count/`kick_next`-duplication nits (round-3 nits) — all
consistent with source and internally coherent.

---

## Suggestion

### S1 — A1-2: the nil-PK guard is narrower than the documented limitation (acceptable, note it)
The moduledoc now says "DB-generated fields (PK or otherwise) are unsupported,"
but the guard only rejects a still-`nil` PK after materialization. A non-PK
DB-generated field (a `:serial`, a DB-side default) would pass the guard yet be
`nil` in the pushed record while the local write generates it — a divergence on
that field. This is a genuine edge case (write_through resources overwhelmingly
use Ash-level defaults, not DB-generated fields), the catastrophic case (PK) is
guarded, and detecting "DB-generated vs Ash-default" generically isn't cheap —
so documenting the rest is a defensible posture. Just be aware the guard and the
doc aren't the same width; if you want them to match, the cheapest enforcement
is a write_through resource-level DSL guard against attributes whose source is
the DB rather than Ash (defer to A5's `can?` consolidation if that's cleaner).

---

## Summary

**0 critical, 0 warnings, 1 suggestion.** The plan is implementation-ready. Round
3 correctly overrode my pass-4 `discard/1` claim (I was wrong: only the `:create`
branch re-derives), dropped the redundant force-back, and fixed the
`create_atomics` guard field — all verified against source. The A0-3 harness
guidance, the cleanup-transaction posture, and the B2-3 denied-set semantics all
check out. The single suggestion is an optional guard/doc width mismatch that's
already mitigated by documentation. Ship it.
