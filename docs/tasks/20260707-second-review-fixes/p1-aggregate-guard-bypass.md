# P1 — Source-computed aggregate loud-failure guard bypassed on non-merged paths

- **Status**: OPEN — re-verified 2026-07-07:
  `ensure_source_aggregates_resolved!` is invoked at exactly one site
  (`proven_coverage.ex:629`, the merged-read branch)
- **Severity**: Medium (silent `%Ash.NotLoaded{}` — the failure shape the module
  docs promise to refuse)
- **Repo**: MDL (ash_multi_datalayer)
- **Source**:
  [20260704 implementation review — M2](../../reviews/20260704-implementation-review.md)
  (added to this tracker per the
  [task-coverage review F2](../../reviews/20260707-second-review-fixes-task-coverage-review.md))
- **Files**:
  `lib/ash_multi_datalayer/orchestrator/proven_coverage.ex:440-442,629`
  (originally `data_layer.ex:561-580,724` pre-extraction)
- **Related task**: [L2](l2-aggregate-fold-notloaded.md) (#23 — the fold
  post-check; same family, different paths)

## Defect

The loud-failure guard for `fold_aggregate_overrides` aggregates runs only on
the merged-read success branch. Unguarded paths, each returning silent
`%Ash.NotLoaded{}` (original review reproduced the first):

1. **Cold-cache miss** → `source_read`.
2. **Kill switch tripped** — flipping the emergency lever silently _changes
   results_ for queries whose folded value is correct when enabled, instead of
   degrading loudly.
3. **Non-mergeable branch**.
4. **Single-layer branch**.

This contradicts the module's own comment ("Refuse it loudly … the one failure
shape this library rejects") and the relationship-aggregates ADR. The original
test (`merge_reads_test.exs`) warms the cache first, so only the merged path was
ever exercised. Note: the code has since moved from `data_layer.ex` into
`ProvenCoverage` — re-map the four branches to their current locations first;
some may have changed shape in the aggregate-folding rework.

## Fix

Move/extend the check to cover `source_read` and the
kill-switch/single-layer/non-mergeable delegations (per the original review), or
whatever the equivalent branches are post-extraction. Coordinate with L2's fold
post-check so the two guards compose rather than duplicate.

## Done when

- [ ] Repro tests: cold-cache, kill-switch, non-mergeable, and single-layer
      reads of an overridden aggregate raise loudly (or resolve) — never silent
      `%Ash.NotLoaded{}`; each fails on unfixed code
- [ ] Existing merged-path guard behavior retained
- [ ] `INTEGRATION=1 mix test` green in MDL
