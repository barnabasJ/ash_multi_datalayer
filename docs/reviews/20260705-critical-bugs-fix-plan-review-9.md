# Plan Review (ninth pass) - critical-bugs-fix-plan.md

**Date:** 2026-07-05
**Scope:** latest amended `docs/plans/critical-bugs-fix-plan.md`, after incorporation of passes 5-7 and cross-checking the concurrently-added pass 8 review.
**Method:** reviewed only residual/new implementation risks in the amended plan, against current `DataLayer`, `Delegate`, `Coverage`, and the prior review findings. This pass is additive to pass 8; it does not restate pass 8's Phase 4.2 wording/signature findings.

## Overall Assessment

The plan now incorporates the prior critical findings and the pass-5 through pass-7 corrections coherently. Pass 8 covers the remaining complement-threading wording and signature precision issues. The additional issue in this pass is the reconcile query shape itself: it must be filter-only, not just PK-only.

This pass found one remaining implementation trap in the Phase 4 reconcile query: the plan says to strip calculations and aggregates, but recordable source reads can still carry a sort that must not be replayed against the cache.

## Findings

### Warnings

- **F1. Reconcile's cache scan must strip `sort`, not only calcs/aggregates.**
  `docs/plans/critical-bugs-fix-plan.md:456-459`, `lib/ash_multi_datalayer/data_layer.ex:516-520`, `lib/ash_multi_datalayer/delegate.ex:48-59`. Phase 4 says the reconcile scan is PK-only with no calculations/aggregates, but it does not say to clear `query.sort`. That matters because Phase 3 now explicitly makes `Coverage.epoch/2` work for the `:calc_sort_source_only` branch: a recordable query whose sort references an uncomputable calculation routes to `source_read` specifically so the cache layer is not asked to sort it. After the source fetch, `maybe_backfill` will run reconcile. If reconcile delegates a PK-only query that still carries the original sort, `Delegate` replays that sort onto the cache layer, reintroducing exactly the unsupported cache evaluation that `sort_references_uncomputable_calc?/3` avoided. Specify the reconcile query as filter-only plus PK select: clear `sort`, `calculations`, `aggregates`, and any other non-filter shaping fields before `Delegate.run_on_layer/2`.

### Suggestions

- **S1. Name the complete reconcile-query shape once.**
  The plan currently describes the scan as "PK-only select, no calcs/aggregates" in prose. To avoid future omissions like `sort`, define it explicitly in Phase 4 as a derived query: original resource/domain/tenant/context and filter region, `select: primary_key`, `sort: []`, `calculations: []`, `aggregates: []`, `distinct: []`, `distinct_sort: nil`, `limit: nil`, `offset: 0`, `lock: nil`. Some of those are already excluded by `recordable?`, but listing the full shape makes the cache scan intentionally filter-only.

## Summary

0 critical, 1 warning, 1 suggestion.

The plan is otherwise implementation-ready from this pass's perspective. Tighten the Phase 4 reconcile-query shape so reconcile cannot accidentally replay source-only sorts against the cache.

---

**Last Updated:** 2026-07-05
