# Handoff — ash_multi_datalayer + ash_remote session (2026-07-03)

Session artifacts:

- **Conversation transcript**: `/home/joba/alembic/.claude/projects/-home-joba-sandbox-ash-multi-datalayer/7ffb06d4-1b48-4c0c-bc99-c2ae783a1383.jsonl`
  (side-agent transcripts under `.../7ffb06d4-.../` subdirectory; background-task
  outputs under `/tmp/claude-1000/-home-joba-sandbox-ash-multi-datalayer/7ffb06d4-1b48-4c0c-bc99-c2ae783a1383/tasks/*.output`)
- **Approved implementation plan**: `/home/joba/alembic/.claude/plans/fizzy-brewing-ember.md`
- **Cross-session memory**: `/home/joba/alembic/.claude/projects/-home-joba-sandbox-ash-multi-datalayer/memory/ash-multi-datalayer-v1-state.md`
- **Repos**: `/home/joba/sandbox/ash_multi_datalayer` (this repo, local only) and
  `/home/joba/sandbox/ash_remote` (origin `git@github.com:barnabasJ/ash_remote.git`, pushed through `8fb1b24`)

## What was built (all committed)

### ash_multi_datalayer — v1 complete + one post-v1 feature

The full 12-phase v1 from `docs/plans/ash-multi-datalayer-plan.md` (status:
implemented), proven by `example/`. History is one commit per phase; read
`git log` for the narrative. Highlights:

- **Core**: `multi_data_layer` DSL + Info; Query accumulation + `Delegate`
  replay (canonical Ash build order, boolean-filter downgrade); coverage
  ledger (per-resource ETS, tenant-partitioned, `:__global__` sentinel);
  interval-DNF subsumption solver; always-on backfill (the `backfill?`
  option was removed by user decision); row-aware invalidation;
  invalidate-before-propagate write dispatch (FR3.5/FR3.6); LRU-capped
  ledger; opt-in divergence sampler (default 0.0, user decision); five
  verifiers; capability negotiation; kill-switch; Debug/TestSupport/mix
  tasks; migration generation via runtime shadow modules
  (`AshMultiDatalayer.Migration` — the stock ash_postgres generator
  discovers by data-layer equality and skips MDL resources).
- **Post-v1: computed-value merge reads**
  (`docs/design/20260703-computed-value-merge-reads-adr.md`): calculation-
  loading reads serve rows from covered cache + ONE `pk in [...]` value
  query; `:stale_cache` fallback; calculations only — resource
  (relationship) **aggregates are loudly unsupported** (`can?` false):
  ash_sql builds related subqueries via the destination resource's data
  layer (ours), which would silently yield `NotLoaded`.
- **Gates** (all green at `d67deae`): 101 tests + 4 property suites (2×10k
  solver/invalidation vs `Ash.Filter.Runtime`), dialyzer 0, credo --strict
  clean, format clean. Integration tests need Postgres at 127.0.0.1:5432
  (postgres/postgres, db `ash_multi_datalayer_test`); run with
  `mix test --include integration`. **Sandbox note**: hex.pm is unreachable
  here — use `HEX_OFFLINE=1` for all mix deps commands.
- **Example** (`example/`): ash_remote's todo app; client resources run
  `:cache Ash.DataLayer.Ets` over `:remote AshRemote.DataLayer`. 17/17
  tests incl. an RPC-counting router proving wire silence on hits
  (T1-T7: identical-read hit, subsumption ×3, write-through with
  server-computed defaults, row-aware invalidation, calc/aggregate
  fall-through equivalence, divergence detection of out-of-band writes,
  kill-switch). Demo: `example/run.sh` → server :4020, LiveView :4002 with
  Browse panel + live cache-stats footer + kill-switch toggle. Live demo
  was performed (page loads drop 5→3 RPCs; the 3 are by-design computed
  loads).

### ash_remote — calculation overhaul (pushed to GitHub, `8fb1b24`)

- **`AshRemote.Expression`**: encodes expression calcs as `expr(...)`
  source when data-expressible (public attr refs; `== != in < <= > >=
  is_nil and/or/not`; `today()/now()`; safe literals incl. date sigils);
  `safe?/1` re-validates on the client (no code injection via crafted
  manifests). Server publishes `"expression"` on calculation fields.
- **Generator**: mirrorable calcs get the REAL expression (filter/sort now
  execute real semantics — e2e-pinned); everything else proxies through
  **`AshRemote.RemoteCalculation`** (no expression on purpose → Ash
  runtime-evaluates filter/sort with server-fetched values; nothing
  evaluable-but-wrong exists anywhere — the old `expr(not is_nil(id))`
  stub is gone).
- **Prefetch + bundling** (user's design): generated read actions
  `prepare AshRemote.PrefetchCalculations` → requested remote calcs ride
  query context → the data layer folds them into the same `/rpc/run` and
  stashes values in record metadata (reads cost no extra request,
  e2e-pinned via RPC counter); when rows came from elsewhere (cache layer,
  `Ash.load`), the first RemoteCalculation fetches the whole bundle in one
  `pk in [...]` request, memoized per read (process dictionary), siblings
  pick their column. Values ALWAYS come from the server ⇒ identical
  results regardless of serving layer (the invariant multi_datalayer
  needs). 83 tests green.

## In flight (interrupted — next steps in order)

1. **Task #20 second half**: in `example/todo_server/mix.exs` and
   `example/todo_client/mix.exs`, replace
   `{:ash_remote, path: "../../../ash_remote"}` with
   `{:ash_remote, github: "barnabasJ/ash_remote"}` so a fresh clone runs
   standalone. Then in the example: `cd todo_server && mix manifest.publish`
   and `cd todo_client && mix remote.gen` to regenerate against the new
   generator (regen is additive; `multi_data_layer` blocks survive; expect
   `overdue?` to gain the real expression, the read actions to gain the
   prepare, and drift warnings for the changed calc — resolve by accepting
   the new calc form, hand-editing to match fresh-gen output if needed).
   Update the T5 test comment in
   `example/todo_client/test/todo_client/multi_datalayer_test.exs` (its
   "stub would say true" rationale is obsolete; values still come from the
   server via merge reads, assertions unchanged). Rerun: library
   `mix test --include integration`, example `mix test`, quality gates,
   commit. Note: mix github deps fetch over git — verify `git ls-remote
   https://github.com/barnabasJ/ash_remote` works from the sandbox (SSH is
   configured; deps.get may need `HEX_OFFLINE=1` for the hex portion).
2. **Untracked file**: `docs/plans/partial-serving-remainder-reads-plan.md`
   appeared in the working tree (from the user's side-agent conversation
   about partial row serving / nil-guarded complements). Review with the
   user: commit it or fold into the future-work section already in the
   merge-reads ADR.
3. **Open by scope**: ash_multi_datalayer task 33 (Hex release) —
   deliberately not done. ash_multi_datalayer itself is not pushed to any
   remote yet (no origin configured).

## Decisions log (user-made, this session)

- `backfill?` DSL option removed — always-on (PRD decision log 2026-07-03).
- `divergence_sampler` default 0.01 → 0.0, opt-in (canary, not a guarantee).
- lib/ must be **data-layer agnostic**: behaviour surface only, no foreign
  Info modules; the AshPostgres migration shim is the one sanctioned
  optional-dep exception.
- Docs first, then implementation; deviations recorded in the design docs
  and PRD decision log.
- Non-mappable calculations: no evaluable stub of any kind — mirrored real
  expression or server-proxied module calc; filter/sort on module calcs is
  whatever Ash natively does (turned out: runtime evaluation, correct).
- No partial row serving (subset from cache + remainder fetch) in v1 —
  all-or-nothing coverage; future-work sketch in the merge-reads ADR.

## Gotchas for whoever continues (also in memory)

- Ash's runtime nil semantics are neither classical nor Kleene (`not`
  propagates nil, `or` collapses it) — De Morgan/dual transforms are
  unsound; the solver keeps `Not` opaque except over `is_nil`. A
  runtime-vs-SQL divergence repro exists (side-agent found it; candidate
  upstream Ash issue: `not (a or b)` with nil operands disagrees between
  `Ash.Filter.Runtime` and AshPostgres).
- ash_sql recurses into related resources' data layers for
  subqueries/aggregates — unfixable from our side; aggregates fail loudly.
- `can?(:select)` must be answered by the source of truth; `source/1` must
  delegate (Ecto schema source); Spark transformers can't add extensions;
  Spark 2.7 verifier failures are compiler diagnostics, not raises;
  `@after_verify` doesn't fire under `Module.create`.
- Test DB rows leak if you run `MIX_ENV=test mix run` probe scripts
  (no sandbox) — truncate `mdl_posts`/`mdl_authors` if unfiltered-read
  tests start failing.
