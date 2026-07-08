# P1 — Source-computed aggregate loud-failure guard bypassed on non-merged paths

- **Status**: DONE — `ensure_source_aggregates_resolved!` now runs on every read
  path: (1) inside `source_read/5` itself — the single function every one of
  cold-cache-miss, lock (`:not_cacheable`), calc-sort-source-only,
  non-mergeable, AND `merged_read`'s own `:stale_cache`/`:miss` fallbacks funnel
  through, one insertion point covers all of them; (2) a new
  `guard_aggregates/2` wraps the kill-switch and single-layer `cond` branches in
  `read/2`, which delegate straight to `Delegate.run_on_layer/2` with no wrapper
  function at all. The original merged-read success-branch call site is
  untouched. **Test limitation, noted honestly**: constructing a fixture where
  an overridden aggregate genuinely comes back `%Ash.NotLoaded{}` (rather than
  ash_sql's own, separate, pre-existing "cannot build an in-database join"
  `ArgumentError` firing first) proved difficult — a same-repo-SQL related
  resource lets ash_sql successfully build the join regardless of MDL's own
  fold/join overrides (they're MDL-only routing decisions ash_sql doesn't know
  about); a non-SQL related resource (`EtsPost`) hits ash_sql's OWN guard before
  `source_read`'s `with {:ok, records} <- ...` even succeeds; a hand-built
  fault- injecting data layer (attempted, see git history) broke ash_sql's
  internal query-preparation pipeline when stripping the aggregate post-hoc. The
  2 tests below assert the task's actual requirement ("raise loudly, never
  silent nil/[]") against ash_sql's own guard, which already produces a loud
  failure for the fixture I could build — but per a stash-and-rerun check, they
  pass identically on unfixed code (ash_sql's guard fires before mine gets a
  chance to), so they do **not** independently discriminate this specific fix.
  The fix itself is verified correct by code review (the call sites above are
  real, the function itself is unchanged and already covered by the merged-read
  branch's existing tests) rather than by a fail-first repro for the
  newly-covered paths specifically.
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
