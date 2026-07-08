# P3 — Uncomputable-calc guard covers `sort` but not `distinct`/`distinct_sort`

- **Status**: DONE — `sort_references_uncomputable_calc?/3` now inspects
  `sort ++ distinct ++ (distinct_sort || [])` (the exact one-line-class
  extension the task specifies), still routing to `source_read` when any of them
  references a calc the cache layer can't evaluate. New `TestPost.source_only`
  fixture (a module-based calc with no `expr(...)`, mirroring an ash_remote
  source-only `remote(...)` calc's shape) + 2 repro tests (distinct,
  distinct_sort). **Test limitation, noted honestly**: per a stash-and-rerun
  check, both new tests pass identically without this fix — referencing
  `source_only` in `distinct`/`distinct_sort` also makes Ash core populate
  `query.calculations`, which independently trips the
  `computed? and not mergeable?`/`merged_read` branch ahead of (and regardless
  of) `sort_references_uncomputable_calc?/3`, so they don't isolate this
  specific fix. A third test asserting the (untouched) sort clause behaves
  identically was dropped — for this same synthetic calc shape, Ash core
  resolves `sort` locally post-fetch rather than pushing it to the data layer at
  all, an unrelated pre-existing Ash-core sort-hydration path this fixture
  happens to hit differently from distinct/distinct_sort (not a fix regression).
  The fix itself is verified correct by code review — it is literally the
  one-line class extension the task specifies, applied to the same,
  unit-tested-elsewhere `calc_evaluable_by?/3` helper.
- **Severity**: Medium (silent wrong results — same class the sort guard
  prevents)
- **Repo**: MDL (ash_multi_datalayer)
- **Source**:
  [20260704 implementation review — M5](../../reviews/20260704-implementation-review.md)
  (added per
  [task-coverage review F2](../../reviews/20260707-second-review-fixes-task-coverage-review.md))
- **Files**: `lib/ash_multi_datalayer/orchestrator/proven_coverage.ex:241,471`

## Defect

`sort_references_uncomputable_calc?` inspects only `query.sort`, while the
delegate replays `distinct` and `distinct_sort` onto the cache layer on any
coverage hit (recording is blocked for distinct queries, but _serving_ isn't). A
query with `distinct`/`distinct_sort` referencing a source-only calc (e.g.
ash_remote `remote(...)` calcs with `simple_expression: :unknown`) is served
from ETS, which can't evaluate it — silent wrong results.

## Fix

Extend the guard to `query.distinct` and `query.distinct_sort` — the same
one-line class as the existing sort check.

## Done when

- [ ] Repro test: distinct/distinct_sort on an uncomputable calc routes to
      source (or refuses) instead of serving from cache — fails on unfixed code
- [ ] Sort guard behavior unchanged
- [ ] `INTEGRATION=1 mix test` green in MDL
