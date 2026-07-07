# P3 — Uncomputable-calc guard covers `sort` but not `distinct`/`distinct_sort`

- **Status**: OPEN — re-verified 2026-07-07:
  `sort_references_uncomputable_calc?` (`proven_coverage.ex:471`) still inspects
  only `query.sort`
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
