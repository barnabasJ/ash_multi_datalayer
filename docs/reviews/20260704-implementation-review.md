# Implementation Review — ash_multi_datalayer v1

**Date:** 2026-07-04
**Scope:** entire library (`lib/`, `test/`, packaging), at commit `b9ddc8c`.
**Method:** four parallel review passes (coverage/solver core, data-layer surface,
write path + support modules, verifiers/DSL/tests/packaging), each primed with the
project's known invariants (non-classical nil semantics, `can?(:select)`
source-of-truth rule, `source/1` delegation, data-layer agnosticism). Every
critical finding was confirmed by **executing failing integration tests against the
real Postgres+ETS stack**; the headline items were reproduced independently by two
or three reviewers and re-confirmed by hand afterwards.

**Baseline at review time:** 126/126 tests green (incl. `INTEGRATION=1` Postgres
suite), `credo --strict` clean, dialyzer has one type regression (see R2).
Working tree clean — no fixes have been applied; this document is findings only.

**Verdict:** the solver core (normaliser, implication, interval, complement,
invalidation predicates) is sound and well property-tested. The integration layer
around it is not release-ready: field-completeness tracking has a systemic hole
that produces **silently wrong query results**, there are two real concurrency
races that violate the "never stale reads" NFR, several loud-failure guards have
bypassed paths, and `mix hex.publish` cannot run today.

---

## Contents

- [Critical findings (C1–C3)](#critical-findings)
- [Major findings (M1–M7)](#major-findings)
- [Release blockers (R1–R3)](#release-blockers)
- [Minor findings (N1–N14)](#minor-findings)
- [Verified sound](#verified-sound)
- [Test-suite gaps and top missing tests](#test-suite-gaps)
- [Suggested fix order](#suggested-fix-order)
- [Repro artifacts](#repro-artifacts)

---

## Critical findings

### C1. Coverage tracks only *selected* fields, not the fields the cache must *evaluate*

**Severity:** critical — silently wrong results. **Confidence:** certain (reproduced
three ways by three independent reviewers; re-confirmed by hand).

**Where:**
- `lib/ash_multi_datalayer/coverage.ex:244-251` — `needed_fields/2` = `select ∪ PK` only.
- `lib/ash_multi_datalayer/data_layer.ex:766-770` — backfill writes only those fields into cache rows.
- `lib/ash_multi_datalayer/coverage.ex:162` — the `covers?` hit check tests only that same select-based set.
- `lib/ash_multi_datalayer/backfill.ex:53-62` — only those fields are force-changed into the cache layer.

**Mechanism:** fields referenced by the query's **filter**, by **locally-evaluated
calculations**, and by **distinct** are neither backfilled into cache rows nor
considered in the field-sufficiency check. On a coverage hit, the cache layer
re-evaluates the full query — including its filter and any local calcs — against
rows that physically lack those fields (`nil`), and under Ash's nil semantics a
nil comparison is a non-match. Ash core does **not** force filter-referenced
attributes into the data-layer select (verified in
`deps/ash/lib/ash/actions/read/read.ex:1507` — `source_fields` covers only
relationship source attributes). Sort fields **are** force-selected by Ash core,
which is the only reason sort survives.

**Reproduced scenarios:**

1. *Identical read returns different results.*
   `TestPost |> Ash.Query.filter(age > 18) |> Ash.Query.select([:id, :name])`.
   Cold read: 2 rows (source miss, backfill, coverage recorded). The **identical
   repeat read** is a coverage hit; ETS re-applies `age > 18` over rows backfilled
   without `age` → **0 rows**.

2. *Silent wrong calculation values.*
   Warm `filter(name == "foo") |> select([:id, :name])`, then the same query plus
   `load(:adult?)` where `adult?` is `expr(age >= 18)` (locally evaluable).
   The merged-read path hits; the calc evaluates over rows lacking `age` and
   returns `adult? = [nil, nil]` instead of `[false, true]`, with zero source
   reads. This is exactly the failure shape `Capability`'s moduledoc names as the
   correctness requirement local evaluation must never produce.

**Blast radius:** any app using `Ash.Query.select` — which is the *norm* for the
flagship AshRemote composition, since AshRemote derives its wire field list from
the select. **No test in the committed suite uses `Ash.Query.select` on the
multi-layer read path**, and the property generators don't model fields at all,
which is why this never fired.

**Fix direction:** `needed_fields/2` must union:
- attribute refs from `query.filter` (e.g. via `Ash.Filter.list_refs/1`),
- attribute refs from `query.sort`, `query.distinct`, `query.distinct_sort`,
- attribute refs from every locally-evaluated calculation expression
  (note: `merged_read` at `data_layer.ex:715` probes coverage with `cache_query`,
  whose local calcs are not reflected in needed fields at all),

on **both** sides: when recording/backfilling an entry (`loaded_fields`) and when
probing (`covers?` subset check).

### C2. Remainder reads ignore `loaded_fields` entirely — rows vanish, then coverage is poisoned

**Severity:** critical — silent row loss that *persists*. **Confidence:** certain
(reproduced by two reviewers; re-confirmed by hand).

**Where:**
- `lib/ash_multi_datalayer/coverage.ex:140-155` — `coverage_split/2` builds the
  covered region `C` from the union of **all** entries' disjuncts with no
  field-sufficiency check against the probe query.
- `lib/ash_multi_datalayer/data_layer.ex:639-676` — `remainder_plan` /
  `remainder_applicable?` consume it; `loaded_fields` is never consulted on this path.

The plan document explicitly mandates this check —
`docs/plans/partial-serving-remainder-reads-plan.md`, rule 4: *"the covered
entry's `loaded_fields` must ⊇ the query's needed fields, exactly like a full
hit"* — the implementation dropped it.

**Reproduced scenarios:**

1. *Wrong field values served.* Seed `{x, 30}`, `{y, 40}`. Read
   `filter(name == "x") |> select([:id, :name])` (records an entry with
   `loaded_fields = {id, name}`). Then read `filter(name in ["x","y"])` with full
   select → returns `[{"x", nil}, {"y", 40}]` — the cached row is served with
   `age: nil` instead of `30`.

2. *Row vanishes from both halves, then coverage is poisoned.* Warm
   `filter(age > 5) |> select([:id, :name])` (rows `"low"` age 3, `"high"` age 30).
   Then a full `Ash.read!()`: the remainder read serves `Q ∧ C` (`age > 5`) from
   ETS — whose `"high"` row has no `age` — so the cache region returns nothing;
   the source side is restricted to `¬C` (`age <= 5 or is_nil(age)`), which
   excludes the row too. Result: **only `["low"]`; `"high"` disappears**. Worse,
   `maybe_backfill` then records Q (the universe) as covered
   (`data_layer.ex:670-673`), so **every subsequent full read is a "hit" that
   keeps dropping the row** until some matching write invalidates the entry.

**Note:** this is distinct from C1. Even after C1 is fixed (needed fields widened),
a *legitimately* narrow-select entry still enters `coverage_split` for a
wider-select query. The remainder planner needs a per-entry gate: only entries
with `needed_fields(query) ⊆ entry.loaded_fields` may contribute to `C`.

`test/integration/remainder_reads_test.exs` never varies select, so this axis is
uncovered.

### C3. Read-miss backfill racing a concurrent write records stale rows *and* stale coverage

**Severity:** critical — persistent stale reads, violating NFR2 ("solver bugs or
unsupported shapes degrade to cache miss, **never stale reads**") and the FR3.6
invariant. **Confidence:** high — reproduced **deterministically** by one reviewer
using a blocking wrapper layer; independently code-verified by another.

**Where:** `lib/ash_multi_datalayer/data_layer.ex:750-789` — the miss path is
`source_read` → `maybe_backfill` → `Coverage.record`, with no guard that
invalidation ran in between. `lib/ash_multi_datalayer/backfill.ex:59-62` —
`force_change_attributes` unconditionally overwrites the cache row.

**Reproduced interleaving:**

1. Reader A misses, fetches rows for Q from the source (pre-write state, `age=20`),
   and stalls before backfill (in the repro, a blocking layer; in production, any
   scheduling delay — the window is the **entire source round trip**, network-wide
   for ash_remote).
2. Writer B commits `age=21` through the full `WriteDispatch` sequence
   (`write_dispatch.ex:78-97`): authoritative write, invalidation (ledger has
   nothing for Q yet — nothing to drop), propagation upserts the fresh `21` row
   into the cache.
3. Reader A resumes: backfills the stale `20` row **over** B's propagated `21`,
   and records coverage for Q.

Every subsequent read of Q is now a coverage hit serving `age=20`. Staleness
persists until an unrelated matching write or LRU eviction. The
row-aware-invalidation ADR's mitigation ("invalidation is synchronous in the
write path so it can't race with *subsequent* reads") covers only reads that
start after the write — not in-flight miss reads.

**Fix direction:** a per-resource+tenant **invalidation epoch/generation counter**:
snapshot it before the source fetch begins; in `maybe_backfill` /
`Coverage.record`, abort (skip backfill and skip recording — the read result is
still returned to the caller) if the generation moved. No test coverage exists
for concurrent read/write interleavings.

---

## Major findings

### M1. `covers?`'s LRU touch resurrects concurrently-invalidated ledger entries

**Where:** `lib/ash_multi_datalayer/coverage.ex:157-173` (snapshot via
`entries/2`, then `touch`) and `:269-271` — `touch` is
`insert(resource, tenant, %Entry{entry | loaded_at: ...})`, an **unconditional ETS
upsert**. **Confidence:** high (interleaving verified against the code; window is
`select` → `insert`, not reproduced under a scheduler).

**Scenario:** reader A's `covers?` snapshots entries including E. Writer B
commits an update; `Invalidation.on_write` drops E; B's cache **propagation then
fails** — the exact case `WriteDispatch`'s invariant is designed for
(`write_dispatch.ex:10-17`: "a later failure can never leave stale coverage
behind"). A then `touch`es E, **re-inserting the dropped entry**. All subsequent
matching reads are full hits serving pre-write rows indefinitely. This defeats
the invalidation-before-propagation ordering from the inside.

**Fix:** `:ets.update_element(table, key, {2, entry})` — it returns `false` when
the key is gone instead of recreating it.

### M2. Loud-failure guard for source-computed aggregates bypassed on every non-merged path

**Where:** `ensure_source_aggregates_resolved!` (`data_layer.ex:561-580`) is
invoked only on the merged-read success branch (`data_layer.ex:724`).
**Confidence:** certain (reproduced by two reviewers).

Unguarded paths, each returning silent `%Ash.NotLoaded{}` for a
`fold_aggregate_overrides` aggregate:
- **cold-cache miss** → `source_read` (`data_layer.ex:750-758`) — reproduced:
  `OverrideAggAuthor` with `fold_aggregate_overrides([:post_count])`, cold cache,
  `load(:post_count)` → `#Ash.NotLoaded<:aggregate, field: :post_count>`;
- **kill switch tripped** (`data_layer.ex:401-402`) — flipping the emergency
  lever silently *changes results* for queries whose folded value is correct when
  enabled, instead of degrading;
- **non-mergeable branch** (`data_layer.ex:419-422`);
- **single-layer branch** (`data_layer.ex:404-405`).

This directly contradicts the module's own comment ("Refuse it loudly … the one
failure shape this library rejects") and the relationship-aggregates ADR. The
existing test (`test/integration/merge_reads_test.exs:220-236`) warms the cache
first, so only the merged path is exercised.

**Fix:** move the check into `source_read` and the kill-switch/single-layer/
non-mergeable delegations.

### M3. Filtering on a foldable relationship aggregate crashes deep in ash_sql

**Where:** `can?({:aggregate, kind})` advertises support (`data_layer.ex:243-247`)
and `:aggregate_filter` falls into the generic read-intersection clause
(`data_layer.ex:275-277`; ETS and AshPostgres both answer true → intersection
true). **Confidence:** certain (reproduced).

`TestAuthor |> Ash.Query.filter(post_count > 1) |> Ash.read!()` raises
`Ash.Error.Unknown` wrapping `KeyError: :__ash_bindings__`: the
aggregate-referencing filter is opaque to the normaliser → `source_read` →
ash_postgres/ash_sql builds the aggregate subquery through the MDL-wrapped
related resource and receives `%AshMultiDatalayer.DataLayer.Query{}` where it
expects an Ecto query — the exact subquery boundary the ADR
(`docs/design/20260704-relationship-aggregates-and-the-subquery-boundary-adr.md`)
says must be refused loudly and cleanly. It is loud, but it's an advertised
capability crashing with an obscure internal error rather than a clean
compile/build-time refusal.

Sorting on the same aggregate works correctly (tested during review, passed).

**Fix:** answer `can?(:aggregate_filter)` false (clean refusal), or route the
filter through the fold path (compute the aggregate, filter at runtime).

### M4. Verifier "rejections" don't block a plain `mix compile` (Spark 2.7 downgrade)

**Where:** Spark 2.7.2's generated `__verify_spark_dsl__` raises the `DslError`
(`deps/spark/lib/spark/dsl.ex:535-556`) but the same function's `catch` clause
(lines 558-575) **catches its own raise** and downgrades it to `IO.warn`.
**Confidence:** high (verified against the spark source; security-adjacent).

Consequences: `field_policies` + multi-layer `read_order` — the case ADR
`20260417-reject-field-policies-with-fallthrough-adr.md` promises will "refuse at
compile time … fails to compile with the expected message" — **compiles with a
warning and runs**, serving cache rows materialised under a different actor
without redaction. Same for tenant-incapable layers on multitenant resources and
non-upsert cache layers. There is no runtime guard (grep: no
`field_policies`/multitenancy checks in `lib/` outside `verifiers/`). The
internal `docs/testing/` doc acknowledges the diagnostic behaviour, but the
README/guide never tell consumers they need `--warnings-as-errors` for the
rejections to actually block.

**Fix options:** document + recommend `--warnings-as-errors` prominently; and/or
add a cheap runtime guard for the field-policies case (the security one); plus a
test pinning the posture (the diagnostic fails under `--warnings-as-errors`).

### M5. Uncomputable-calc guard covers `sort` but not `distinct`/`distinct_sort`

**Where:** `sort_references_uncomputable_calc?` (`data_layer.ex:592-600`)
inspects only `query.sort`; `Delegate.to_layer_query` replays `distinct` and
`distinct_sort` onto the cache layer on any coverage hit
(`delegate.ex:36-42`), and `covers?` doesn't consider distinct (recording is
blocked at `coverage.ex:94-100`, but *serving* isn't). **Confidence:** medium —
mechanics verified in code; not reproduced because this repo has no
unevaluable-calc fixture (the ash_remote example's `remote(...)` calcs with
`simple_expression: :unknown` are the real-world trigger).

A query with `distinct`/`distinct_sort` referencing a source-only calc would be
served from ETS, which can't evaluate it — the same silent-wrong-results class
the sort guard was explicitly added to prevent (see its own comment at
`data_layer.ex:588-591`). Fix is the same one-line class: extend the guard.

### M6. Multitenancy with `global? true`: invalidation never crosses tenant partitions

**Where:** `lib/ash_multi_datalayer/coverage/invalidation.ex:61-67` — `on_write`
scans only `Coverage.entries(resource, tenant)`; `write_dispatch.ex:102-110`.
**Confidence:** mechanics certain from code; real-world reachability depends on
host resource config (attribute-strategy multitenancy with `global? true`).
Verify against Ash multitenancy semantics before fixing.

**Scenario:** a nil-tenant read (legitimately spanning all tenants under
`global? true`) records an entry under `:__global__`. A tenant-T write later
changes a matching row; `on_write(resource, T, ...)` never touches the
`:__global__` partition → the global entry keeps serving pre-write rows. Mirror
case for nil-tenant writes vs tenant-scoped entries.

**Conservative fix:** tenant-scoped writes also sweep `:__global__`; nil-tenant
writes sweep all partitions. There is no multitenant test resource in the suite.

### M7. N+1 aggregate folding

**Where:** `fold_aggregates` → `fold_one` issues `Ash.load` **per record per
aggregate** (`data_layer.ex:470-543`). **Confidence:** high on the code; medium
on real-world impact.

A 100-row page loading `count :todos` on a cold cache against a remote source is
100 sequential related source reads per aggregate — a hot-path performance
landmine for exactly the flagship remote composition. `Ash.load(records, load)`
batches. Correctness of the fold itself is fine (verified — see
[Verified sound](#verified-sound)).

---

## Release blockers

The one open task is the Hex release; it cannot ship as-is.

### R1. `mix hex.build` fails today, twice over (confirmed by running it)

- `** (Mix) Can't build package with overridden dependency crux, remove
  'override: true'` — `mix.exs:40` has `{:crux, "0.1.3", override: true}`. The
  exact pin `"0.1.3"` would also over-constrain consumers; ash already pulls crux
  transitively (`>= 0.1.2 and < 1.0.0-0`), so relax to `~> 0.1` or drop.
- After removing the override it still fails: **Missing metadata fields:
  description, licenses, links** — `mix.exs` has no `description`, `package`,
  `source_url`, or `docs` config at all.
- No `LICENSE` file in the repo root.
- No `{:ex_doc, ...}` dep and no `docs:` config → `mix docs` doesn't exist;
  hexdocs publish will fail; the README's links into `docs/guides/…` won't
  resolve on hexdocs without `extras`.
- Hex's default file set ships `priv/test_repo/migrations/*` (test fixtures) in
  the package — needs an explicit `files:` list.

### R2. Dialyzer regression from the OTP 29 toolchain pin

ash 3.29 defines `Ash.Resource.record/0` **only when OTP < 29**
(`deps/ash/lib/ash/resource.ex:15`: the `@type` sits inside
`if String.to_integer(System.otp_release()) < 29`). Commit `63644b6` pinned the
toolchain to erlang 29.0.3, so the type vanished and dialyzer now emits
`unknown_type` (exit 2). **13 spec references across 7 files** need
`Ash.Resource.record()` → `Ash.Resource.Record.t()`:
`write_dispatch.ex` (34, 42, 50), `delegate.ex:20`, `value_merge.ex` (70, 71),
`backfill.ex` (21, 47, 48, 83), `divergence.ex:23`, `coverage/invalidation.ex`
(29, 59).

### R3. CHANGELOG describes a different library

- Claims a `backfill?` DSL option and a `RegisterUnderlyingExtensions`
  transformer — neither exists in `lib/` (the transformer was removed due to the
  "transformers cannot add extensions" constraint; extensions are now listed
  manually and `ValidateLayers.required_sections_present` enforces it; `backfill?`
  was removed per the PRD decision log — always-on).
- Says ValidateLayers "ensures at least two declared layers" (single layer is
  accepted) and misdescribes ValidateMultitenancy ("all layers agree on strategy"
  vs the actual "every layer `can?(:multitenancy)`").

---

## Minor findings

| # | Where | Issue |
|---|-------|-------|
| N1 | `data_layer.ex:102-104` | `divergence_sampler` schema is bare `type: :float` — `1.5` / `-0.3` accepted; `Divergence.sample?` does `:rand.uniform() < rate`, so 1.5 = always-sample and negative = never, silently. Docs promise 0.0..1.0. |
| N2 | DSL schema | `local_evaluation_overrides` / `fold_aggregate_overrides` names are never validated against declared calcs/aggregates — a typo silently no-ops a correctness escape hatch (e.g. a clock-dependent calc the operator believes is excluded from local eval isn't). |
| N3 | `coverage.ex:56-60` | `insert/3` (used by `record` and `touch`) lacks the `ArgumentError` rescue all sibling table ops have — if the TableOwner dies in the `ensure_table` → insert window, the user's **read** crashes instead of degrading to cold cache. |
| N4 | `coverage.ex:187-211` | `record`'s fingerprint-dedupe + cap-check + insert is non-atomic across processes: concurrent identical records duplicate entries and can overshoot `ledger_max_entries`. Memory/perf only (duplicates are semantically identical). |
| N5 | `coverage.ex:256-267` | `dedupe_key` is `phash2` — a collision silently skips recording a genuinely new filter. Perf-only (`covers?` re-proves implication, so never wrong serving); ~2⁻²⁷/pair. |
| N6 | `data_layer.ex:791-802`, `write_dispatch.ex:85-94` | `emit_read` / `Telemetry.write` compute `Coverage.size/2` — an `:ets.select_count` **full-table traversal** — on every read and write; O(table) per operation at the 10k-entry cap. |
| N7 | `divergence.ex:66-69` vs `telemetry.ex:26-28` | `pk_delta` puts raw PK values into telemetry metadata; the "PII-safe by construction" claim holds only for filters — natural-key PKs would leak. |
| N8 | `backfill.ex:44-45` vs `:106-110` | Doc promises "non-nil loaded attributes" as the default field set, but `default_fields/1` returns all attribute names and `Map.take` copies `nil` / `%Ash.NotLoaded{}` through `force_change_attributes` — a partially-loaded authoritative record (plausible with remote layers) writes NotLoaded sentinels into cache rows. |
| N9 | `write_dispatch.ex:107-116, 152` | Even `{:upsert_skipped, …}` (no row changed) triggers `Invalidation.drop_all` of the whole tenant partition — correct but needlessly clears all coverage on no-op upserts. |
| N10 | `data_layer.ex:407-408, 275-277` | `can?({:lock, _})` uses read-intersection (ETS false → false), so the `run_query` lock branch that routes locked reads to the source is dead code. Same "delegate to source of truth" shape as `:select` — if locked reads are meant to work, `{:lock, _}` should be answered by the source alone. Loud failure today, no corruption. |
| N11 | `verifiers/reject_multi_node.ex` | Reads `Application.get_env` at **compile time** — an ack placed in `runtime.exs` won't silence it, and neither the message nor the README says the config must be compile-time. Also warns on single-layer `read_order` configs that have no node-local cache (false positive). |
| N12 | `data_layer/info.ex` | Duplicates every schema default (`10_000`, `0.0`, `true`, `[]`) as `get_opt` fallbacks — currently consistent, pure drift risk. |
| N13 | `migration.ex:92-94` | `shadow_built?` will `Module.create`-overwrite a genuine user module named `X.PostgresShadow` / `X.PostgresShadowDomain` (or adopt one that happens to export `spark_dsl_config/0`); a shadow built earlier in a long-lived VM is reused with stale `@resource_refs` after recompiles. Edge footguns — mix tasks normally run in fresh VMs. |
| N14 | compile warnings | `backfill.ex:14` unused `require Logger`; `coverage.ex:270` struct-update dynamic-type warning on `%Entry{entry \| ...}` — both appear on every compile. |

**Agnosticism sign-off needed:** `data_layer.ex:540` calls
`Ash.DataLayer.Ets.aggregate_value/6` — a non-behaviour internal of a foreign
data layer, outside the one sanctioned Migration exception. It ships in ash core
(no dep risk) and is used as a shared fold primitive; grep confirms it's the only
other occurrence. Rule tension, not breakage — decide and record in the PRD
decision log.

**Verifier gap (low confidence):** `ValidateLayers.section_required?` only
inspects top-level `section.schema` for `required:` opts — a layer whose
mandatory config lives in nested sections/entities would slip through (compiles,
fails at runtime). No known concrete instance.

---

## Verified sound

Checked deliberately and found correct — this is what the review did *not* find
problems in:

**Solver core** (the hard part):
- **No De Morgan / classical negation on general predicates.**
  `normaliser.ex:84-88` makes `Not` opaque except directly over `is_nil` (the
  only two-valued predicate). `complement.ex:105-142` applies De Morgan only
  after every leaf is replaced by its *exact, total* nil-safe complement
  (`¬(a > 5)` → `a <= 5 or is_nil(a)`), so the composition is classical — gated
  by the C/¬C partition property (2k runs, nil-heavy rows, vs
  `Ash.Filter.Runtime`).
- **Truthy (not `== true`) matching** honored in invalidation
  (`invalidation.ex:43-47`) and the property ground truth
  (`test/support/generators.ex:88-93`).
- **Interval logic**: open/closed bound containment (`interval.ex:162-185`),
  conjunction tightening and unsatisfiability (`normaliser.ex:365-398`),
  `is_nil`/`not_nil` vs nil-rejecting comparisons, empty/singleton/nil-member
  `in` lists (`normaliser.ex:243-274`) — hand-verified and cross-checked by the
  10k-run implication property suite.
- **Implication** iterates the union of both sides' constrained attributes
  (`implication.ex:41-55`); type mismatches and unproven kind pairs are `false`
  (conservative). No cross-engine comparison drift (both sides use `Comp`; any
  compared pair comes from the same attribute).
- **`recordable?`** excludes limit/offset/distinct/distinct_sort/lock
  (`coverage.ex:94-100`); serving a limited/sorted probe from fully-covered
  cache is sound (set-complete superset).
- **Verifier/solver predicate drift is impossible by construction**:
  `ValidateSolverSupportedPredicates` calls the same `Normaliser.supported?/2`
  the runtime prover uses.

**Write path:**
- Ordering matches the ADR and FR3.5–3.6: authoritative fail-fast (error returned
  verbatim, nothing touched), **invalidation before propagation**, propagation
  failure logged + telemetried but never fails the write — safe precisely because
  invalidation already degraded the entry to a miss. Well tested
  (`layer_failure_test.exs`, all three scenarios). (The gap is the *read-side*
  races C3/M1, not the write-side ordering.)
- Bulk/atomic writes cannot bypass invalidation:
  `can?(:update_query | :destroy_query | {:atomic,_})` are all false
  (`data_layer.ex:250-252`), so Ash streams per-record through `WriteDispatch`;
  upserts `drop_all`; unknown/crashing filter evaluation drops conservatively.
- Kill switch polarity correct; consulted on `run_query` and write propagation;
  invalidation runs unconditionally while disabled (FR6.2); `enable!` erases the
  key. (Exception: the M2 aggregate path.)
- Divergence sampler: default 0.0 (PRD decision ✓), never alters caller-visible
  results, shadow-read failure silent; tested at 1.0 and 0.0.
- Backfill: always-on, no `backfill?` option anywhere (PRD decision ✓); a partial
  backfill failure correctly skips `Coverage.record`
  (`data_layer.ex:772-785`) — though nothing tests it (see missing test #1).

**Read path structure:**
- `can?(:select)` source-of-truth-only (`data_layer.ex:264-269`) and `source/1`
  delegation with pre-verifier tolerance (`data_layer.ex:332-342`) both honor the
  documented invariants. A sweep of the remaining `can?` clauses found the
  intersection answers conservative (false ⇒ loud refusal, not silent stripping)
  — except `{:lock,_}` (N10) and `:aggregate_filter` (M3).
- `pk_merge` prefers freshly-fetched source rows and dedupes by PK
  (`data_layer.ex:693-697`); remainder eligibility excludes
  sort/limit/offset/distinct/lock, so no split-read pagination/ordering bugs;
  limit is never pushed to only one side.
- Aggregate folding (`fold_one`) is a faithful mirror of
  `Ash.DataLayer.Ets.do_add_aggregates` (verified side-by-side: tenant/actor
  sourcing, uniq?/include_nil?/default_value, aggregate-filter via
  `Ash.Filter.Runtime.filter_matches` with truthy semantics, runtime sort before
  first/list, PK fallback). Related-row loads route through the related
  resource's own MDL read path, so folds serve from cache only when covered.
  `:custom` kind correctly excluded. (Perf is M7.)
- Transaction surface (`transaction/rollback/in_transaction?`) consistently
  delegates to the authoritative layer; `can?(:transact)` is write-intersection,
  so multi-layer stacks never advertise transactions they can't honor.
- `Delegate` replay: canonical step order, empty-value skips,
  select-as-optimisation skip, boolean_filter downgrade, tenant/context
  propagation — correct; tenant is threaded through every split-read path.
- ValueMerge: computed values always sourced fresh (source always overwrites
  cache), `:stale_cache` abandons the merge whole, value-query failure fails the
  read — no partial results; matches the 20260703 ADR. (Row field-completeness
  is C1, a coverage-layer bug, not a merge bug.)
- Supervisor/TableOwner: crash ⇒ restart with empty ledger = cold cache (tested);
  missing supervisor degrades to kill-switched behaviour with a once-per-node
  warning (tested).

**Verifier bypass checks that came up clean:** layers/orders defined via
variables (resolved by Spark before verify); policies added by other extensions
(verifiers run on the final dsl_state); `Module.create` resources — the e2e
collector test passes because Elixir 1.20's `@after_verify` **does** fire for
`Module.create` (the previously-recorded gotcha is outdated).

---

## Test-suite gaps

**State:** committed suite fully green — 126 tests under `INTEGRATION=1`
(79 with Postgres excluded). No assertion-free tests; telemetry properly asserted
via `attach` + `assert_receive` across the integration files.

**Property suites** (3 files, 5 properties — implication soundness vs
`Ash.Filter.Runtime` at 10k runs, complement partition, invalidation exactness)
are genuinely meaningful: generators cover nil row values, `not` nodes, `is_nil`
both ways, all 8 operators, truthy ground truth. Weaknesses:
- `in` lists are `min_length: 1`, so the empty-`in` → `:unsatisfiable` branch
  (`normaliser.ex:245`) is never generated;
- no relationship-path or calc refs in generated filters (opacity paths untested
  by property);
- only 5 rows sampled per case;
- **fields are not modelled at all** — the C1/C2 axis was structurally invisible
  to the properties.

**Untested modules:** `backfill.ex` and `delegate.ex` (indirect only),
`divergence.ex` (one integration test), mix tasks
`ash_multi_datalayer.disable|enable|inspect` (zero tests;
`generate_migrations` is tested). `normaliser_test.exs` has only 3 tests (calc
opacity).

**Top missing tests, in value order:**

1. **Read-path backfill failure must not record coverage.** The code does the
   right thing (`data_layer.ex:772-785`), but nothing tests it. Rig a failing
   cache layer during read fall-through; assert no ledger entry and the next
   identical read misses with correct rows. If this regresses, the ledger claims
   coverage over rows the cache doesn't have — the library's worst failure class.
2. **Cross-tenant isolation end-to-end.** Warm tenant A's coverage; the same
   filter as tenant B must miss and return only B's rows; a write in A must not
   invalidate B. Only the tenantless `:__global__` partition is asserted today
   (`subsumption_test.exs:165`). A partition regression is a cross-tenant data
   leak. (Also the vehicle for M6.)
3. **Select-varying reads across every read path** — the C1/C2 repros, adopted
   into the suite (full hit, remainder, merged-read + local calc), plus a
   field-modelling extension to the property generators.
4. **E2E verifier enforcement through Spark** for the security-relevant verifiers
   (RejectFieldPolicies, ValidateMultitenancy — currently only unit-called), plus
   a test pinning that the diagnostic fails under `--warnings-as-errors` (M4's
   contract).
5. **Normaliser degenerate inputs**: `in: []` → unsatisfiable, `in` containing
   `nil` → opaque, contradictory conjunctions dropped, the 32-disjunct DNF cap →
   opaque (`normaliser.ex:127-129`). Each is a "conservative on unknown"
   invariant an optimisation could silently break; none are generator-reachable.
   Also DSL boundary tests for N1/N2 once validation is added.

---

## Suggested fix order

1. **C1 — widen `needed_fields`** (filter + sort + distinct + local-calc refs, on
   both record and probe sides). Root fix; also removes half of C2's surface.
2. **C2 — per-entry field gate in `remainder_plan`/`coverage_split`** (plan rule 4).
3. **C3 — invalidation epoch** guarding backfill/record on the miss path.
4. **M1 — `touch` via `:ets.update_element`** (one-line class).
5. **M2/M3 — aggregate guards**: `ensure_source_aggregates_resolved!` on all
   source-serving paths; `can?(:aggregate_filter)` → false (or fold+runtime-filter).
6. **M4 — verifier posture**: document `--warnings-as-errors`, runtime guard for
   field policies, contract test.
7. **M5/M6** — distinct guard extension; multitenancy sweep decision.
8. **R1–R3 — packaging**: crux, package metadata, LICENSE, ex_doc, `files:`,
   `Ash.Resource.Record.t()` migration, CHANGELOG rewrite.
9. Minors opportunistically (N3, N6, N14 are the ones worth doing with the above).

Adopt the repro tests (below) into `test/integration/` as the regression suite
for steps 1–3.

---

## Repro artifacts

Failing reproduction tests for C1/C2 (3 tests, all fail against `b9ddc8c`;
re-confirmed by hand at review close) are preserved next to this report:

```
docs/reviews/repro_fields_test.exs.artifact
```

The `.artifact` suffix keeps it out of `mix test`'s glob. To run it:
`cp docs/reviews/repro_fields_test.exs.artifact tmp/repro_fields_test.exs &&
INTEGRATION=1 mix test tmp/repro_fields_test.exs` — or rename it into
`test/integration/` when fixing C1/C2 (it's already `@moduletag :integration`
compatible and should pass once fixed). The C3
race repro used a blocking wrapper layer and was cleaned up; rebuilding it is
straightforward from the interleaving described in C3.

The working tree was left untouched by the review (verified `git status` clean
at close).
