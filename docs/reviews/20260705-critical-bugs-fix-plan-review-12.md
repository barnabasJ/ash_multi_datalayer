# Plan Review (pass 12) — the four-times-amended critical-bugs-fix-plan.md

**Date:** 2026-07-05 **Scope:** the fourth amendment of
`docs/plans/critical-bugs-fix-plan.md` (the version whose disposition tables
cover passes 1–10), reviewed against all prior passes and the source. (Written
into slot 12 per instruction; no file 11 existed at review time.) **Method:**
each pass-8/9/10 disposition row was checked against the originating finding and
the implementing plan text; the amended Phase 3 snapshot/bump bullets and the
Phase 4.2 reconcile-query shape were re-derived, including the compound failure
interleavings behind the pass-10 S2 assumption.

**Verdict:** the fourth amendment is faithful and the plan has converged — the
six pass-8/9/10 rows are all correctly adopted, the reconcile query is now fully
enumerated with the right rationale for the `sort` clear (it is the one field
`recordable?` does not already exclude, and the `:calc_sort_source_only` branch
makes it load-bearing), and the corrected Phase 4.2 justification says exactly
what pass 8 established. This pass finds **no mechanism defects**: every
protocol re-derivation (pair epoch, two-step snapshot, non-fatal bump,
check-insert-verify, threaded ¬C, filter-only reconcile) comes back sound. What
remains is three consistency residues and one refinement to a stated invariant —
all editorial-class. The plan is ready for Phase 0.

---

## Verified: fourth-amendment adoptions re-derived

- **p9-F1/S1 — filter-only reconcile query.** The full shape is enumerated once,
  in the right place, and the plan's added rationale is precisely correct:
  `recordable?` (`coverage.ex:94-100`) excludes
  limit/offset/distinct/distinct_sort/lock but **not** sort, so `sort: []` is
  the single load-bearing clear, and the `:calc_sort_source_only` branch is the
  path where retaining it would replay an uncomputable calc-sort onto the cache
  layer mid-reconcile. Matches this reviewer's independent adjudication of pass
  9 exactly (including the nuance that the remainder path is immune —
  `remainder_applicable?` requires an empty sort).
- **p8-F1 — corrected recompute justification.** The false "entry set is stable"
  claim is gone; the replacement names the four bump-free mutators and states
  the real invariant ("scan region and fetch region must be the same object").
  Faithful to the finding, including the `¬C′ ⊃ ¬C` cache-erosion consequence.
- **p8-F2 / p10-S1 — two-step snapshot, stated as such.** The "deliberately
  non-atomic" wording with the fetch-follows-snapshot soundness argument and the
  absence-after-seed ⇒ abort corner are all in the snapshot bullet. Both passes'
  versions of the finding are fully absorbed.
- **p8-F3 — signature note reconciled.** Phase 3.3 now names both `record`
  additions (`epoch0` + pre-normalised probe) and defers the packaging (opts vs
  `record/5`) to the implementer while requiring 3.3 and 4.2 to describe the
  same function. Consistent.
- **p8-F4 — trail wording.** The label note now correctly records that
  review-3's first published version raised the originals and was rewritten in
  place, with pass 4 as the surviving source.
- **p10-S2 — same-table assumption stated.** Adopted for the code comment, with
  the future-split consequence (explicit invalidation abort) named. One
  refinement below (F2).
- **Pass-10 completeness:** pass 10 contained exactly S1 and S2 (0 criticals, 0
  warnings); both are dispositioned. Its extra verification — that the threaded
  complement is always `{:ok, filter}` on the remainder path, since an `:empty`
  complement implies a full hit and a `:universe` complement implies no split —
  is correct and worth keeping in mind for the implementation's typespec.

---

## Findings

### F1 (consistency): the p5-W1 disposition row still asserts what p8-F1 disproved

The passes-5–7 table's first row ends: "recompute-in-place rejected as
discipline violation **despite being epoch-safe** (Phase 4.2)". Two tables
later, the p8-F1 row records the opposite ("recompute of `¬C` is unsound, not
merely undisciplined"), and the Phase 4.2 body text now agrees with p8-F1. The
stale clause is exactly the kind of authoritative-looking sentence a future
reader greps into: it cites the epoch guard as blessing the recompute the body
text forbids. Reword the p5-W1 row (e.g. "…rejected; pass-8 F1 later established
the recompute is unsound, see that row") so the two tables and the body agree.

### F2 (precision): the "bump and drops fail together" invariant is one-legged — the recreated-table interleaving is closed by the incarnation, not by co-failure

The p10-S2 adoption says the C3-reopening arrangement ("bump fails, epoch
unmoved, drops _succeed_") is "unreachable" because bump and drops share one
table and fail together. That is the common case, but not the whole story: the
table can be **recreated between the failed bump and the drop-scan** (TableOwner
restart is precisely the failure being tolerated). Then the drops _do_ succeed —
on the fresh table, removing entries that post-restart readers may have just
recorded. This still cannot reopen C3, but for a different reason than the
comment states: any reader holding a pre-restart snapshot fails its check on
**incarnation mismatch** (fresh raw `unique_integer`), and post-restart readers'
entries were recorded from post-write fetches, so dropping them costs hit rate
only. The invariant the code comment should state is therefore two-legged:
_either_ bump and drops fail together (same table, same death), _or_ any
interleaving in which drops outlive a failed bump necessarily crossed a table
recreation, which refreshed the incarnation and aborts every stale reader. Since
p10-S2's whole purpose is to arm a future refactor with the correct load-bearing
invariant, record the complete one — a `:persistent_term`-backed epoch would
break _both_ legs, which strengthens, not weakens, the "must abort invalidation
explicitly" clause.

### F3 (completeness): name `maybe_backfill`'s final signature once

`maybe_backfill` has now accumulated three contract changes across amendments:
it receives **source-half rows** instead of `merged` (Phase 3.4), the
**`complement:`** option (Phase 4.2), and it needs **`epoch0`** for the
pre-upsert check (Phase 3.2) — but unlike `record`, whose signature evolution is
tracked explicitly in Phase 3.3, `maybe_backfill`'s full new contract must be
assembled from three separate bullets. One sentence — e.g.
`maybe_backfill(query, resource, read_layers, source_rows, epoch0, opts)` with
`opts[:complement]` — mirrors the precision the plan already applies to
`record`, and prevents the implementer from, say, threading `epoch0` through
`opts` in one call site and positionally in another.

### F4 (trivial): the header still says "the seven plan reviews" above a list of ten

Line 3 correctly says "after ten review passes"; the input paragraph then
introduces "the seven plan reviews" followed by links to passes 1–10. Update the
count (or drop the number — it has gone stale on every amendment).

---

## Summary

0 mechanism defects, 4 editorial-class findings (1 table self-contradiction, 1
invariant stated one-legged, 1 signature named once, 1 stale count). Every
protocol in the plan — pair epoch with two-step seed, check-insert-verify,
non-fatal bump under the two-legged invariant, source-half-only
backfill/reconcile with threaded ¬C, filter-only reconcile query, opaque gates,
fingerprint widening under epoch discipline — now survives re-derivation with no
gaps this pass could find. All pass-8/9/10 findings are faithfully dispositioned
and none reopened. The plan is ready for Phase 0; the four items above can land
with the first implementation commit rather than another amendment cycle.

---

**Last Updated:** 2026-07-05
