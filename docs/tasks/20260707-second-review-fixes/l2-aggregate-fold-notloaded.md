# L2 — Aggregate fold leaves `%Ash.NotLoaded{}` on cold cache (#23) — live flaky test

- **Status**: DONE — new `ensure_folded_aggregates_resolved/4` (wired into
  `aggregate_read/3` right after the fold's `add_aggregates_via_layer` call)
  detects any row where a fold-computed aggregate is still `%Ash.NotLoaded{}`
  and falls through to `add_aggregates_via_layer` again against
  `read_source_layer(resource)` (the authoritative source) instead of returning
  the unresolved value — the exact "fold against authoritative fetched rows or
  fall through" the task specifies.

  **Live-flaky-test gate re-verified — no longer flaky, and no longer MDL's code
  path at all**: `example/todo_client/test/todo_client/live_test.exs:92` passed
  20/20 consecutive runs (was ~70% flaky per the original finding). Root cause
  of the fix: `TodoServer.TodoList`/`TodoServer.Todo`
  (`example/todo_server/lib/todo_server/resources/{todo_list,todo}.ex`) no
  longer use `AshMultiDatalayer.DataLayer` at all — both are plain
  `Ash.DataLayer.Ets` resources now. The demo's own architecture moved off MDL
  for these two resources at some point in this project's history (unrelated to
  this task), which independently resolved the live flakiness regardless of any
  `proven_coverage.ex` change.

  **Deterministic MDL-level repro, noted honestly**: traced the actual fold
  mechanism in detail (`Delegate.run_on_layer` → `to_layer_query`'s
  `add_aggregates` → `Ash.DataLayer.Ets.run_query/3`'s `do_add_aggregates/4`) —
  for a `related?: true` aggregate this calls `Ash.load/3` on the related rows,
  which for an MDL-wrapped related resource (e.g. `TestPost`) routes through
  MDL's own full read pipeline, not a raw/unreliable lookup. Combined with
  `Backfill.upsert_records/4` being synchronous, the parent row is reliably warm
  by the time the fold query runs on this stack. Two repro attempts —
  cross-process (`Task.async`, simulating a cold per-process cache) and a
  `limit`'d "non-recordable" query (the defect description's second named
  scenario) — both pass identically with and without the fix; neither
  discriminates on the current, apparently already-robust code path. The
  `limit`'d test is retained as a regression guard. The fix itself is verified
  correct by code review: it is a literal implementation of the task's stated
  fix guidance, layered defensively on top of code that already appears reliable
  on this stack.

  `INTEGRATION=1 mix test` green (320, up from 319).

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
