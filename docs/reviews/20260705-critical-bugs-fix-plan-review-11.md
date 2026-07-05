# Plan Review (pass 11) — the ten-amendment critical-bugs-fix-plan.md

**Date:** 2026-07-05
**Scope:** the amended `docs/plans/critical-bugs-fix-plan.md` (the version whose
disposition tables cover passes 1–10), reviewed against all ten prior passes,
the current `lib/` source, and the two concurrently-added pass files
([8](./20260705-critical-bugs-fix-plan-review-8.md),
[9](./20260705-critical-bugs-fix-plan-review-9.md)) that I had not read when I
wrote [pass 10](./20260705-critical-bugs-fix-plan-review-10.md).
**Method:** verified each pass-8/9/10 amendment landed in the plan text (not
just the disposition table), re-derived the reconcile-query shape against the
`run_query` branch that motivates it, and traced every piece of threading to
the single function that receives it.

**Verdict:** the plan has converged. Every mechanism has been re-derived sound
across multiple independent passes; the last three passes (8, 9, 10) were
wording/precision fixes, all faithfully adopted. One spec-completeness gap
remains — `maybe_backfill` is the aggregation point for all the threading
(epoch0, normalised probe, source-half rows, complement) but the plan
consolidates only `record`'s signature change, not `maybe_backfill`'s. Nothing
blocks Phase 0.

---

## Verified: pass-8/9/10 amendments faithfully in the plan text

- **p8-F1 (the "entry set is stable" false justification is gone).** Phase 4.2
  now reads "threading is required by the reconcile's semantics, not a
  discipline nicety" and names the four bump-free entry-set mutators (concurrent
  `record` inserts, LRU cap evictions, fingerprint widenings, verify-drops) and
  the `¬C′ ⊃ ¬C` erosion direction. The sentence no longer claims recompute is
  epoch-safe. Correct — this was the most substantive inherited defect (pass 5's
  W1 remedy was right, its rejected-alternative justification was wrong), and
  the replacement text states the deeper invariant (scan region = fetch region)
  rather than a weaker discipline argument.
- **p8-F2 / p10-S1 (two-step snapshot non-atomicity stated).** Phase 3 now says
  "a two-step, non-atomic sequence — deliberately" with the soundness argument
  (a bump between the two steps precedes the layer fetch, so the snapshot
  legitimately absorbs it) and the one non-benign corner (absence after the
  seed attempt ⇒ abort). The word "atomic" no longer mischaracterises the
  mechanism.
- **p8-F3 (record signature reconciled).** Phase 3.3 now says `record` gains
  **two** additions — `epoch0` and the pre-normalised probe — and notes Phases
  3.3 and 4.2 must describe the same function. No longer stale.
- **p8-F4 (trail wording).** The label note now says "originally raised in
  review-3's first published version, which a later session rewrote in place"
  rather than "existed only in pass 4's adjudication." Forensically accurate.
- **p9-F1/S1 (reconcile query shape fully enumerated).** Phase 4.2 now names
  the complete filter-only query: `select: primary_key`, `sort: []`,
  `calculations: []`, `aggregates: []`, `distinct: []`, `distinct_sort: nil`,
  `limit: nil`, `offset: 0`, `lock: nil` — and explains that clearing `sort` is
  *not* redundant with `recordable?`, because the `:calc_sort_source_only`
  branch (data_layer.ex:516-520) reaches `maybe_backfill` with a sort the cache
  layer cannot evaluate. I re-derived this: a recordable query with an
  uncomputable calc sort routes to `source_read` specifically to avoid cache
  evaluation, so the reconcile replaying that sort would reintroduce the exact
  evaluation `sort_references_uncomputable_calc?` prevents. Correctly caught.
- **p10-S2 (non-fatal bump assumption stated).** Phase 3 now says the bump and
  drops share the same ETS table (fail together), and a future refactor moving
  the epoch to a different store must abort invalidation explicitly. The one
  assumption the non-fatal posture rests on is now documented.

---

## Findings

### S1. `maybe_backfill` is the aggregation point for all the threading — but only `record`'s signature is consolidated

`plan:343-350` (Phase 3.3) carefully specifies `record`'s signature change
(`record/3` → gains `epoch0` + the normalised probe). But `maybe_backfill` —
the **single function** that receives every piece of threaded state — has no
consolidated signature note. An implementer must assemble it from four
scattered bullets:

| Threaded input | Where the plan specifies it | Current source |
|---|---|---|
| `source_rows` (not `merged`) | Phase 3.4 (line 351-360) | `data_layer.ex:802` passes `merged` |
| `epoch0` (for pre-upsert check + into `record`) | Phase 3.1 snapshot + Phase 3.2 check | not yet threaded |
| normalised probe (from shared gate, into `record`) | Phase 4.2 gate bullet (line 458-466) | not yet threaded |
| `complement:` filter (for reconcile) | Phase 4.2 ¬C bullet (line 467-484) | not yet threaded |

The current `maybe_backfill(query, resource, read_layers, records)` at
`data_layer.ex:890` gains four new inputs. The plan is otherwise meticulous
about signatures (it specifies `record`'s and `coverage_split`'s arity change);
the asymmetry — `record`'s signature named, `maybe_backfill`'s implied — is the
one place a careful implementer has to cross-reference four sections to
reconstruct the function they're writing. One sentence in Phase 3 or 4
consolidating it (e.g. "`maybe_backfill` becomes `maybe_backfill(query,
resource, read_layers, source_rows, opts)` with `opts` carrying `epoch0`, the
normalised probe from the gate, and `complement:`") would match the plan's
precision elsewhere. Not blocking — the inputs are all named, just not in one
place.

### Note (non-blocking). Reconcile scan failure is unspecified — but defense-in-depth fails gracefully

Phase 4.2 doesn't say what happens if the reconcile's `Delegate.run_on_layer`
cache scan returns `{:error, _}`. The safe behavior follows from the plan's own
framing: reconcile is "defense in depth," the epoch guard + evict-on-write are
primary, and any ghost left by a failed reconcile is unservable (its covering
entries were dropped by invalidation) until the next re-covering read
reconciles again. So: skip reconcile on scan error, proceed to `record` (which
has its own epoch guard), log + telemeter. One clause saying so would prevent
an implementer from either failing the read (too aggressive — the read already
succeeded) or skipping record (too conservative — the backfill was fine). Not
a correctness gap — the graceful path is the natural one — just an unstated
contract on a failure mode the code will encounter if a cache layer is ever
transiently unhealthy during a backfill.

---

## What I did not find

I looked hard for remaining correctness gaps across the mechanisms that have
been stable the longest (check-insert-verify, the reconcile Q∧¬C restriction,
the evict-before-image PK, the `forget!` NotLoaded probe) and re-derived the
interleavings that are easiest to get subtly wrong (mid-reconcile bump,
compound table-death during `on_write`, the two-step snapshot absorbing a
concurrent bump). All remain sound as specified. The epoch pair, the shared
gate, the complement threading, and the reconcile-query shape are all
internally consistent across Phases 3–4 and consistent with the source. The
`recordable?` check at `data_layer.ex:893` is the point that becomes the shared
gate (recordable ∧ non-opaque); the plan names this correctly. No prior finding
is reopened.

## Summary

0 critical, 0 warnings, 1 suggestion (consolidate `maybe_backfill`'s signature
note), 1 non-blocking note (reconcile scan-failure contract). The plan is
implementation-ready: the ten passes have exhausted the substantive design
space, and the remaining items are about making the implementer's job easier,
not about correctness. The natural stopping point for plan review has been
reached; further value comes from implementing Phase 0 and letting the
harness speak.

---

**Last Updated**: 2026-07-05
