# Review: the 2026-07-06 review-findings fix plan

**Date**: 2026-07-06 **Input**:
[the fix plan](../plans/20260706-review-findings-fix-plan.md), checked against
[the whole-repo review](../reviews/20260706-whole-repo-review.md) and the source
of both repos at the plan's stated commits. **Verdict**: the plan is strong and
largely faithful to the review — the repro-first discipline, the verified Facts
section, and the M-2 residual reasoning are exactly right. **One critical design
flaw** (the M-3 fix as written does not close the race it targets), **one dropped
finding** (M-7), and a handful of under-specified steps that will cost time at
the gates if not addressed up front. Details and source citations below.

The claims in this review were verified by reading the actual source, not just
the plan's restatement of it. Severities: **critical** = the step will not
achieve its stated invariant as written; **warning** = an omission that blocks
the gate or risks a false-pass; **suggestion** = precision/clarity.

---

## Critical

### C1 — M-3 fix is insufficient: epoch bump alone does not close the missing-row cache hit

The plan (Phase A3) proposes that reconcile's ghost eviction "bump the
invalidation epoch … before destroying the row … per-PK entry-dropping is an
optimization; epoch bump is the mechanism the C3/C4 arc already trusts." That
second sentence is wrong for *this* race, and the fix as designed leaves the bug
open for the exact interleaving the review describes.

**Why.** `Coverage.record/5` (`lib/ash_multi_datalayer/coverage.ex:357`) commits
an entry with a check-insert-verify on the epoch (`verify_or_drop/4`,
`coverage.ex:425`). The epoch bump the plan adds at eviction aborts only records
that are *in-flight between their own insert and verify* at the moment of the
bump. It does **nothing** to an entry that already committed. In the review's
M-3 race, reader R2 "records entry P (postdates W's bump, so record succeeds)"
**before** R1's reconcile eviction runs — so P is already committed when R1
evicts. Bumping the epoch at eviction cannot retroactively drop P.

And `covers?/3` (`coverage.ex:239`) — the hit path — does **not** re-check the
epoch at all. So after R1 destroys the physical row `r`, P still sits in the
ledger claiming coverage over `r`'s region, and the next read is a cache *hit*
served from a cache that no longer has `r`: a lasting missing-row cache hit, the
exact outcome M-3 exists to prevent. The epoch bump narrows the window for new
records but does not remove committed orphans.

`Invalidation.on_write/4` — the "mechanism the C3/C4 arc trusts" — does **three**
things (`coverage/invalidation.ex:84`): `bump_epoch`, `evict_physical_row`, **and
drop every ledger entry whose filter matches the changed row** (`should_drop?`,
line 40). The drop is load-bearing: it is the only step that removes a
committed entry like P. The plan reinvents one of the three and omits the one
that matters here.

**Fix direction (for the plan).** The reconcile eviction must invalidate
coverage of the evicted ghost the way `on_write` does for a destroy — bump the
epoch **and** drop entries whose filter covers the ghost's PK
(`should_drop?(entry, ghost_row, nil)`). Cleanest: reuse `on_write`'s machinery
(a destroy-style invalidation: before/after = ghost/`nil`) rather than hand-rolling
a bare epoch bump. Keep the plan's batching note (bump once per batch, not per
ghost) — but batch the *entry drops* too, not just the bump. Per-PK
entry-dropping is not an optimization here; it is the fix.

### C2 — M-3 regression test (A0-3) as described may not reproduce the bug

The plan says "reader R1 blocks after its source fetch; writer creates `r` …; R1
resumes and reconciles." But `maybe_backfill/6`
(`proven_coverage.ex:690`) checks `Coverage.epoch_moved?/3` at its top
(`proven_coverage.ex:698`) **before** it calls `reconcile/5`. If R1 blocks at the
source fetch and W writes during the block, that top-of-`maybe_backfill` guard
sees the epoch move and **aborts before reconcile runs** — so `r` is never
evicted and the test passes with *no fix applied* (false confidence), or "R1
resumes and reconciles" simply never happens.

The reachable race window is the gap **after** the `epoch_moved?` check passes
and **before/during** `reconcile`'s cache scan (`reconcile_layer/6`,
`proven_coverage.ex:796`, whose `Delegate.run_on_layer/2` is the parkable layer
call). To reproduce deterministically with the `BlockingLayer` harness
(`test/support/blocking_layer.ex`), R1 must block on the **cache-layer reconcile
scan** (after the epoch check), not at the source fetch (which runs on the source
layer and returns before the guard).

**Fix direction (for the plan).** Reword A0-3 to block R1 inside the reconcile
scan (the cache-layer read), and confirm the test *fails for the review's stated
reason* (committed entry P orphaned by the eviction) rather than the narrower
in-flight-record sub-case — which is the only sub-case the epoch-bump-only fix
would incidentally close. Combined with C1, this means: implement the
on_write-style fix, then this test exercises the committed-entry path that the
fix's drop step must handle.

---

## Warnings

### W1 — M-7 is silently dropped

M-7 (hit-path phantom absence during updates) is [LOW-MED] in the review with a
documented floor ("document the anomaly explicitly"). It appears **nowhere** in
the plan — not in a phase, not in the Out-of-scope list (which names only M-10
and M-11's perf items). Even if the decision is doc-only, the plan should say so
explicitly so it isn't read as an oversight. Add it to Out-of-scope with the
chosen disposition (doc-only floor recommended) or give it a one-line phase.

### W2 — M-6 fix omits two required downstream edits

The plan adds a `classify` head for forbidden → `:auth` and a new
`error_class: :auth`. Two things that must change for that to work are not
mentioned:

1. The `error_class` attribute is constrained
   (`sync/transformers/inject_outbox.ex:84`):
   `constraints: [one_of: [:transient_exhausted, :rejected, :conflict]]`. `:auth`
   is not in the set, so parking with `error_class: :auth` will be rejected by
   the constraint. Add `:auth` to the `one_of`.
2. `apply_result/6` (`flush.ex:95`) only branches on `:rejected` and
   `:transient`. A third clause is needed so `:auth` parks immediately (the
   "parks immediately (no retries)" behavior the plan describes lives here, not
   in `classify`). The plan implies this but doesn't name the function.

### W3 — M-2 fix under-specifies the record-materialization step

Reordering `write_through/3` to `drain → push → local_write` means the pushed
record can no longer come from `local_write`'s return. The plan says "reuse
`Target.record_from_entry`-style construction or apply the changeset in-memory,"
but `write_through` deliberately creates **no outbox entry**, so there is no
`entry` for `record_from_entry` to consume — that reuse does not fit the actual
code shape. The hard part (especially for `:create`, where the PK and any
DB-generated defaults don't exist until the local commit) is materializing a
pushable record *before* committing locally. The plan should call out a concrete
approach (e.g. generate the PK/defaults on the changeset up front, or push a
changeset-derived map the target can upsert) so the A1 gate isn't where this is
discovered. The residual-convergence reasoning (server-ahead is benign) is
correct and well-argued.

### W4 — "independent until the final gate" overstates the A/B separation

The intro says the two workstreams are independent until the final gate, but A2
and B2-1 are semantically coupled: `Flush.classify/1` must treat the new
`AshRemote.Error.Transport` as `:transient` and a `Forbidden` inside it as
`:auth`. The plan *does* handle this in the landing-order section (land B2-1
first, or have A2 accept both shapes during overlap) — just flagging that the
"two workstreams are independent until the final gate" framing in the intro is
slightly overstated given the coupling the landing-order section already
acknowledges.

---

## Strengths

- **Repro-first discipline is exemplary** — every behavioral fix lands with a
  test that failed before it, and the gates are runnable and specific (named test
  files, named assertions, suite-green + credo-green). This is the single biggest
  strength.

- **The Facts section is accurate.** I verified the load-bearing ones against
  source: `rebase/2` order (apply → `drop_chain`, `api.ex:183`); `write_through`
  order (`drain → local → push`, `write.ex:42`, contradicting its own moduledoc
  at `write.ex:33`); `classify/1` heads (no forbidden head, `flush.ex:199`);
  both `resolve_resource` sites calling `Module.concat([input])` before the
  membership check (`server.ex:435`, `server/channel.ex:177`, and the channel's
  `rescue ArgumentError` truly never fires); `Notifier.payload/4` serializing all
  public attributes with no actor (`server/notifier.ex:75`); and `BlockingLayer`
  existing and reusable (`test/support/blocking_layer.ex`).
- **M-2 residual reasoning is correct.** Server-ahead-by-one converges via the
  next realtime push/refresh; local-ahead-with-no-outbox is the write-losing
  direction. Identifying which residual is benign is the hard part and the plan
  gets it right.
- **M-8, M-4, M-5, R-1, R-3, R-5, R-9 fix directions are sound and match
  source.** The `transaction/4` fallback throw (`data_layer.ex:357`/`:368`), the
  no-co-commit orphan path (`write.ex:206` `in_transaction(nil, fun)`), the
  discarded `discard_local` result (`api.ex:137`), the tenant-free wire
  (`protocol.ex:30`, no tenant key), the field-policy-blind payload, the verbatim
  `safe_message`, and the denied-topic rejoin storm — all confirmed, all fix
  directions appropriate.
- **Backward-compatible protocol change.** R-1's "an absent key is the old
  behavior" note is the right call and keeps the wire format non-breaking.
- **Scoping is sensible.** M-9 (Phase 4a structural debt) as its own arc, M-10
  (splits) and M-11 perf deferred — these are the right things to keep out of a
  correctness pass.

---

## Suggestions

### S1 — R-2: the two resolve_resource sites check *different* sets
`server.ex:437` tests membership in `resources(otp_app)`; `server/channel.ex:179`
tests membership in `publications(otp_app)` (derived). A single
`:resource_map` may not serve both unless it's the union (or two maps). The plan
says "same fix both sites" and "both already enumerated" — true, but the sets
differ; note it so the map is built from the union (or per-site) rather than one
assumed to equal the other.

### S2 — M-1: "capture the chain's identifying keys first" is unnecessary
`drop_chain/1` (`api.ex:391`) reads the chain via `record_chain/1`, which queries
on `entry.resource`/`record_pk`/`target` — fields on the immutable, in-memory
`entry` struct. They're available before or after the drop regardless of order.
Harmless (defensive), but the stated rationale ("capture first") implies a
mutability that isn't there; dropping it keeps the fix description honest.

### S3 — Realtime field-policy strip (R-3): consider `changed/2` too
The plan focuses on `"data"`. `changed/2` (`server/notifier.ex:98`) also
serializes touched public attributes from `notification.data`, so a policied
field's *new value* leaks via `"changed"` even if stripped from `"data"`. Strip
from both, as the review's "exclude them from `data`/`changed`" wording implies.

---

## Summary

**1 critical, 4 warnings, 3 suggestions.** The critical item (C1/C2, the M-3
fix-and-test design) must be reworked before Phase A3 is attempted: the
epoch-bump-only eviction does not remove committed covering entries, and the
test as worded is likely to block on the wrong side of the existing
`epoch_moved?` guard. Adopt the review's own alternative — on_write-style
invalidation (bump + drop covering entries + evict) — which is the proven
instrument and makes the test's committed-entry path the thing being validated.
The warnings (M-7 dropped; M-6's missing constraint + `apply_result` clause;
M-2's record materialization) are each a small addition to the plan text that
will save a gate cycle. Everything else is in good shape.
