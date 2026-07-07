# L2 — Aggregate fold leaves `%Ash.NotLoaded{}` on cold cache (#23) — live flaky test

- **Status**: OPEN
- **Severity**: Low (silent wrong values; currently flaking a live test ~70%)
- **Repo**: MDL (ash_multi_datalayer)
- **Verification**: AGENT — **reproduced live**:
  `example/todo_client/test/todo_client/live_test.exs:92` fails ~70% of runs
  (`todo_count == %Ash.NotLoaded{}` instead of `2`)
- **Source**:
  [20260707 implementation review — L2](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Original finding**: #23
- **Plan ref**: Workstream A phase A3 item 6
- **Files**: `lib/ash_multi_datalayer/orchestrator/proven_coverage.ex:331-433`

## Defect

No aggregate-fold post-check: `copy_aggregate_values(row, nil, _aggs) -> row`
leaves `%Ash.NotLoaded{}` on a cold-cache fold; non-recordable
(limit/offset/distinct) queries aren't folded against fetched base rows.

## Fix

Per plan A3 item 6: add a post-check that output aggregates are resolved;
non-recordable aggregate queries fold against the authoritative fetched rows or
fall through — never return silent `%Ash.NotLoaded{}`.

## Done when

- [ ] Repro test (plan A0 repro 19): cold-cache and limited/distinct aggregate
      queries return resolved values or fall through — fails on unfixed code
      with `%Ash.NotLoaded{}`. This deterministic repro is the **primary,
      measurable gate** (pass-5 review: the flaky-live-test gate below is not
      measurable on its own)
- [ ] `example/todo_client` `live_test.exs:92` passes green across a concrete
      run:
      `cd example/todo_client && for i in $(seq 1 20); do mix test     test/todo_client/live_test.exs:92 || exit 1; done`
      (20 consecutive passes; was ~70% flaky) — a supplement to the
      deterministic repro, not the sole evidence
- [ ] `INTEGRATION=1 mix test` green in MDL
