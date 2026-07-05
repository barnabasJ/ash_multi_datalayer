# Orchestrator Extraction + LocalOutbox — Implementation Plan

**Metadata:**

- Type: plan
- Status: in progress — **Phases 1 & 2 complete** (pure-refactor gate + walking
  skeleton, all 11 spike items green)
- Created: 2026-07-05
- Topic: orchestrator-extraction, local-outbox, local-first
- Depends on: [critical-bugs fix plan](./critical-bugs-fix-plan.md) (**hard
  prerequisite** — C1–C4/M1 live in exactly the code Phase 1 moves),
  [orchestrator behaviour ADR](../design/20260705-orchestrator-behaviour-adr.md),
  [sync-state-as-Ash-resources ADR](../design/20260705-sync-state-as-ash-resources-adr.md),
  [LocalOutbox RFC](../design/20260705-local-outbox-orchestrator-rfc.md)
- Reviewed (all incorporated):
  [review 1](../reviews/20260705-orchestrator-extraction-and-local-outbox-plan-review.md)
  (F1–F11),
  [adversarial pass 1](../reviews/20260705-orchestrator-extraction-plan-review.md)
  (B1–B3, D1–D8),
  [pass 2](../reviews/20260705-orchestrator-extraction-and-local-outbox-plan-review-pass2.md)
  (F1–F7),
  [pass 3](../reviews/20260705-orchestrator-extraction-and-local-outbox-plan-review-pass3.md)
  (R1–R11),
  [review 2](../reviews/20260705-orchestrator-extraction-and-local-outbox-plan-review-2.md)
  (R1–R7 — incl. the ash_oban named-instance gap),
  [pass 4](../reviews/20260705-orchestrator-extraction-and-local-outbox-plan-review-pass4.md)
  (P1–P3 — the four-enqueue-site enumeration),
  [review 3](../reviews/20260705-orchestrator-extraction-and-local-outbox-plan-review-3.md)
  (V1–V4; V4's stray live.ex change committed at `f5f9a89`),
  [review 4](../reviews/20260705-orchestrator-extraction-and-local-outbox-plan-review-4.md)
  (W1–W2, bookkeeping) and
  [pass 5](../reviews/20260705-orchestrator-extraction-and-local-outbox-plan-review-pass5.md)
  (N1–N2; source-verified `job.conf.name` + context threading — both declare the
  plan ready to execute)

## Executive Summary

- **Goal 1 — extraction**: pull the routing policy out of
  `AshMultiDatalayer.DataLayer` (the `run_query/2` decision tree — exact line
  counts drift as the fix plan lands) and `WriteDispatch` into an
  `AshMultiDatalayer.Orchestrator` behaviour; today's behaviour becomes
  `Orchestrator.ProvenCoverage`, the default. Pure refactor, gated on the
  unchanged test suite.
- **Goal 2 — the proof**: `Orchestrator.LocalOutbox`, a second strategy with
  inverted authority (local layer authoritative, remote layers asynchronously
  replicated), implemented **without touching the shell's data-path code** — the
  demonstration that the seam is real.
- **Goal 2b — honest capabilities** (a **v2 scope addition**, per plan-review
  pass 3 R4 — motivated by the aggregate-filter crash M3, the dead lock branch
  N10, and the `:transact`-vs-`transaction/4` contradiction; it sits on the
  Phase 7 critical path deliberately): `can?` answers stop being hardcoded
  intersections/falses in the shell and are **derived per strategy from the
  underlying layers** (Phase 4a): authority-only for source-executed features,
  per-query cache-capability degradation for serving, verify-time upsert/destroy
  checks for propagation targets — with hardcoded `false` surviving _only_ as
  documented bypass-guards (bulk/atomic/query-mutations would skip orchestration
  entirely; ash_sqlite answering `true` to `update_query` is exactly why blind
  delegation is unsafe).
- **Goal 3 — the stack**: sync state as app-owned Ash resources (igniter-
  generated), async flush on Oban via ash_oban, pause/resume for offline/online,
  transient errors retried by Oban, terminal errors as parked resource rows the
  app hooks. ProvenCoverage's coverage ledger ported onto the same pattern
  (ETS-backed Ash resource) — with the explicit caveat that this sub-goal is
  **benchmark-gated** (Phase 5): if the probe budget fails, the default stays
  raw ETS behind the same seam and the resource port ships opt-in only, meaning
  the inspectability/hookability win applies only to apps that opt in. That
  degraded outcome is an accepted result, not a silent redefinition (review D3).
- **Goal 4 — inbound direction**: `LocalOutbox.refresh/3` (forced read through
  the replica written back into the local layer, dirty-chain rule) plus
  `handle_external_change/2` / `handle_external_gap/2` behaviour callbacks. The
  `ash_remote_cache` _library_ dissolves: its notifier + lifecycle guard fold
  into **ash_remote** as user utilities over those callbacks (deliberately no
  product name), wiring realtime notifications into per-strategy reactions —
  invalidate for ProvenCoverage, refresh for LocalOutbox.
- **Goal 5 — the showcase**: `ash_remote_cache`'s example (already
  authenticated + realtime) built out into the flagship — real Phoenix apps, a
  collaborative-todo domain where **each strategy plays its natural role**
  (sqlite+remote LocalOutbox for the offline-necessary working set; ETS+remote
  ProvenCoverage for read-mostly reference data; remote-only for online-only
  features), ash_oban on both sides, Oban Web, one SQLite file holding data +
  outbox + jobs, offline toggle, and the **full conflict-resolution UI**
  (three-way diff, all verbs, field-level merge → rebase, chain view, sync
  center).

## Facts the plan depends on (recorded so it survives context loss)

- **Deps (Phase 2 update — hex.pm now reachable; user-authorised).** The
  original constraint was "no hex.pm access; all deps in `~/.hex/packages/hexpm`
  at oban 2.23.0, ash_oban 0.8.10, ash_sqlite 0.2.17, ecto_sqlite3 (≤0.22.0),
  exqlite (≤0.36.0), igniter 0.8.2, phx_new (≤1.8.5), oban_web 2.12.5 + oban_met
  1.2.0." **Deviation, recorded (Phase 2):** the cached `ecto_sqlite3 ≤0.22.0`
  pins `decimal ~> 1.6 or ~> 2.0` (**< 3.0**, the CVE-affected range), which
  cannot coexist with `ash 3.29.3 → ecto 3.14 → decimal ~> 3.0` — the resolver
  cannot place `ecto_sqlite3` at all. Hex became reachable and the user
  confirmed updating is fine (decimal CVE), so **`ecto_sqlite3` is pinned to
  0.24.1** (requires `decimal ~> 3.0`, `ecto ~> 3.14`, `exqlite ~> 0.22`) —
  resolves cleanly, `exqlite` lands at 0.38.0, `decimal` stays 3.1.1 (the
  patched latest). Locked: oban 2.23.0, ash_oban 0.8.10, ash_sqlite 0.2.17,
  ecto_sqlite3 0.24.1, exqlite 0.38.0.
  `ash_sqlite 0.2.17 → ecto_sqlite3 ~> 0.12` admits 0.24.1. Pin exact versions
  in mix files like the existing `crux` pin.
- **oban_web 2.12.5 verified** (package source): dep requirements all satisfied
  by our pins (oban ~> 2.21, oban_met ~> 1.1, phoenix ~> 1.7, phoenix_live_view
  ~> 1.0); its own dev/test stack runs on **ecto_sqlite3**, so SQLite/Lite is a
  first-class citizen; assets are **pre-built and self-contained**
  (`priv/static/app.{css,js}` — no esbuild/tailwind/node step, which matters
  offline); mounts via `import Oban.Web.Router` +
  `oban_dashboard "/oban", oban_name: ...`.
- **Offline constraint on phx.new**: the default asset pipeline downloads
  esbuild/tailwind platform binaries from the network at setup — the example
  must be generated `--no-assets` (hand-rolled layout CSS like todo_client's,
  and oban_web brings its own).
- **Oban Lite engine** (`Oban.Engines.Lite`) supports unique jobs (verified in
  `oban-2.23.0` source: `fetch_unique/2` implemented in the Lite engine).
- **ash_oban 0.8.10 trigger DSL** (verified in package source): `action`
  (required), `where` (filter expr), `sort`, `queue`, `max_attempts`, `on_error`
  (update action after last attempt), `on_error_fails_job?`, `scheduler_cron`
  (string | `false`), `worker_read_action`, `read_action`,
  `stream_with :keyset | :offset | :full_read` (fallback if ash_sqlite keyset
  streaming misbehaves), `worker_module_name`/`scheduler_module_name` (set them
  — avoids the "define module names explicitly" upgrade churn), `list_tenants`,
  `trigger_once?`. Functions: `AshOban.run_trigger/3` (immediate per-record
  enqueue), `AshOban.schedule/3`, `AshOban.schedule_and_run_triggers/2`.
  ash_oban checks data-layer capabilities (`can?(:transact)`,
  `can?({:lock, :for_update})`) instead of assuming Postgres — with ash_sqlite
  it will not lock (SQLite has no `FOR UPDATE`); single-writer chain-head
  discipline covers this (Phase 2 verifies).
- **Oban ordering**: no FIFO guarantee even at queue concurrency 1 (retry
  backoff reorders). Per-PK ordering therefore lives in the flush action's
  chain-head check on `seq`, never in queue configuration.
- **ash_sqlite 0.2.17 capability surface** (verified,
  `lib/data_layer.ex:444-514` — the driver for F1 and the Phase 4a
  capability-derivation work): hardcodes `can?(:transact) == false` and
  `can?({:lock,_}) == false` (SQLite transactions work fine through
  `Repo.transaction/1` — the Ash capability is what's switched off) and
  `can?(:multitenancy) == false`; answers **true** to `:update_query`,
  `:destroy_query`, `{:atomic, :update | :upsert | :create}` (other
  `{:atomic,_}` hit the catch-all false — review-2 R5), `:bulk_create` — the
  features MDL must keep refusing regardless of layer support, because they
  mutate inside one layer and bypass orchestration. Also
  `distinct`/`distinct_sort` false, `{:aggregate,_}`/`:aggregate_filter` false,
  no keyset capability flag (keyset streaming rides Ash-level
  filter+sort+limit). Repo option is
  `{:or, [{:behaviour, Ecto.Repo}, {:fun, 2}]}` with a per-query
  `context.data_layer.repo` override, and ecto_sqlite3 inherits Ecto's
  dynamic-repo machinery — two runtime instances over two SQLite files are
  achievable (review-2 R2).
- **ash_oban 0.8.10 cannot enqueue into a named Oban instance** (review-2 R1,
  verified): `run_trigger/3`, `schedule/3`, `run_triggers/3`, and the generated
  schedulers/action workers all call bare `Oban.insert!/1` — the default global
  `Oban`, always. The single `:oban` opt that exists applies only to
  `drain_queue` in `schedule_and_run_triggers/2`. Consequence: the
  `oban_instance` option is implemented by **MDL owning its Oban touchpoints**
  (see Phase 3), not by threading an option through ash_oban. The mechanism's
  substrate is **source-verified** (pass-5): `job.conf` is populated at worker
  dispatch (`oban/queue/executor.ex:57-61` injects the running instance's
  `%Oban.Config{}` into the job before `perform/1`); ash_oban's generic-action
  trigger worker threads the job into the action context
  (`define_schedulers.ex:1057-1060` → `AshOban.build_context/2` →
  `context[:ash_oban][:job]`), so `Flush.run/2` can read `job.conf.name`; and
  generic-action triggers do **no** `worker_read_action` before the action —
  `Flush.run/2` genuinely is the worker's first Ash call, making it the sound
  establishment point for `put_dynamic_repo` + instance name.
- **ash_oban snooze path exists first-class** (review F11, verified):
  raising/returning `AshOban.Errors.SnoozeJob` maps to `{:snooze, seconds}` in
  `check_for_oban_return` (`ash_oban.ex:1326`); combined with the verified
  `snooze_job` semantics (re-schedule + `max_attempts` increment), the
  offline-class zero-budget-burn design needs only a confirmation test.
- **Fix-plan status (updated after pass-3 R1, verified at `b290e0d`)**: the
  critical-bugs fix plan is **fully landed** — Phases 0–7 committed (`6b5ab7c`
  harness+C1/C2 → `ba7e3d0` C3 epoch + C4 evict/reconcile/ `forget!` → `e1fa3cc`
  M1 → `8213163` suite hardening → `2aca728` dialyzer regression fix → `b290e0d`
  docs); `forget!/3` exists at `lib/ash_multi_datalayer.ex:53`; suite grew to
  ~97 unit/property tests (count = what `mix test` reports; grep-counting
  `test`/`property` macros undercounts parameterized tests — review-3 V3) + the
  `INTEGRATION=1` suite. **Phase 0's gate is satisfiable now** — Phase 1 can
  branch from `b290e0d`. `test/support/blocking_layer.ex` exists (fix-plan Phase
  0 harness) — Phase 4 extends it, not creates it.
- **Current code shape**: policy to move lives in
  `lib/ash_multi_datalayer/data_layer.ex` (`run_query/2` tree, aggregate
  fold/join dispatch, remainder/merged/source reads) and
  `lib/ash_multi_datalayer/write_dispatch.ex`. Mechanisms that stay put and get
  called by both strategies: `Backfill`, `Coverage.*`, `ValueMerge`, `Delegate`,
  `SqlPassthrough`, `Capability`, `KillSwitch`, `Telemetry`, `Migration`.
  Verifiers in `lib/ash_multi_datalayer/verifiers/` gain per-strategy
  applicability. The ledger is raw ETS in `coverage.ex` +
  `coverage/table_owner.ex` (keyed `{tenant, entry_id}`, LRU via `loaded_at`,
  cap via `Info.ledger_max_entries/1`).
- **`../ash_remote_cache` current shape** (read 2026-07-05): five `lib/` modules
  (review F4; see Phase 6 for the full inventory and destinations). The two
  headline components are pure consumers of MDL/ash*remote public APIs;
  `CacheLayer` (149 lines, the largest) is the C4 stopgap the fold-back retires.
  `InvalidationNotifier` — an `Ash.Notifier` on generated client resources
  (realtime notifications dispatch through `Ash.Resource.Info.notifiers/1` like
  local writes); recovers the before-image by point-querying the cache layer
  (the realtime pipeline never writes locally), then calls
  `Coverage.Invalidation.on_write/4`. `LifecycleGuard` — registered via
  `AshRemote.Realtime.listen_lifecycle/1`; on `:resubscribed`/`:join_denied`
  drops the whole ledger for resource+tenant (notifications are
  **at-most-once**; a gap carries no row-level info). Gotcha recorded in its
  README: `notifiers:` must be a compile-time literal list on `use Ash.Resource`
  or the `multi_data_layer` DSL silently breaks. Its **example** is the richest
  of the three repos and the seed for Phase 7: todo_server with
  **ash_authentication** (User/Token, JWT, auth_plug), owner-or-public
  collaborative policies, `AshRemote.Server.Notifier` realtime publishing, RPC +
  web routers on one endpoint; todo_client with session/current_user wiring, a
  `RealtimeBridge` client notifier (LiveView refetch over PubSub, ordered
  \_after* the invalidation notifier), counting-router, and
  invalidation-wiring/live/multi-datalayer test suites.
- **Example precedent**: `example/todo_client` (ETS cache over
  `AshRemote.DataLayer`, LiveView UI, RPC-counting router, in-BEAM e2e test that
  boots `todo_server` via Bandit as a `:test`-only path dep). ash_remote pinned
  to a git ref; `mix remote.gen` regenerates client resources from
  `priv/manifest.json`.

## Non-Goals (v1 of this arc)

- **Library-side/automatic merging**: CRDTs, causal ordering, server
  reconciliation — the _library_ never merges on its own. Inbound
  notification-driven **refresh is in scope** (RFC "Inbound changes"), and
  **application-mediated merge through `rebase/2` is the supported hook** (Phase
  7's field-level merge UI builds a changeset and submits it through `rebase/2`
  — the app decides, the library replicates the decision; review pass-2 F4).
  Concurrent edits the app doesn't resolve converge by LWW-or-park. The
  sanctioned inbound writes are `discard_local`, hydration, and `refresh/3`.
- Partial hydration / cache-miss fall-through in LocalOutbox (that's
  ProvenCoverage's territory; a hybrid would be a third strategy).
- Batched or cross-record-transactional flushes; entry retention/audit mode.
- Multi-node LocalOutbox (single-node ack stays, same as ProvenCoverage).
- Oban Pro features (chains, workflows) — plain Oban only; Pro is not in the
  cache and not assumable for client devices.
- Porting the _subsumption machinery_ to resources — only the ledger's _storage_
  moves; `Normaliser`/`Implication`/`Complement` stay pure modules.
- **Stacked orchestrators** (ProvenCoverage between L1–L2 + LocalOutbox between
  L2–L3 on one resource): design recorded in the
  [stacked-orchestrators RFC](../design/20260705-stacked-orchestrators-rfc.md)
  (exploratory), implementation demand-gated and post-arc. This arc only carries
  the Phase 1 funneling note above.

## Phases

Sequencing rule: Phase 0 gates everything. Phases 1 and 2 are independent of
each other. Phase 3 needs 2; Phase 4 needs 1+3; Phase 4a needs 4 (it moves the
shell/ProvenCoverage behaviour changes out of both the pure-refactor gate and
the clean-seam diff); Phase 5 needs 1 (and profits from 3's extension plumbing);
Phase 6 (the ash_remote fold-in) needs 4's inbound callbacks; Phase 7 (the
example) needs 3+4+4a+6; Phase 8 closes.

### Phase 0 — prerequisites

1. **Land the [critical-bugs fix plan](./critical-bugs-fix-plan.md) first.**
   C1–C4/M1 sit in `run_query`/backfill/invalidation — exactly the code Phase 1
   relocates. Refactoring around known-broken code doubles review surface; the
   extraction must move _fixed_ code. Gate (hardened per review B3): the fix
   plan is **committed** (not merely green in a working tree), `forget!/3`
   exists, and `mix test && INTEGRATION=1 mix test` are green at the exact
   commit Phase 1 branches from. **Status: satisfied at `b290e0d`** (facts
   section) — Phase 1 may branch.
2. Vendor/pin dep versions (from the cache facts above) in the library's
   `mix.exs` (`oban`, `ash_oban`, `ash_sqlite` as `optional: true`) and lock
   them where used non-optionally (example app, test env — the library's own
   test suite needs them to exercise LocalOutbox).

### Phase 1 — orchestrator extraction (pure refactor)

**Objective**: the behaviour seam per the
[behaviour ADR](../design/20260705-orchestrator-behaviour-adr.md), with
ProvenCoverage behaviourally identical to today.

**Deliverables**:

- `AshMultiDatalayer.Orchestrator` behaviour — **all 13 callbacks from the ADR**
  (review F6): `read/2`, `run_aggregate_query/3` (optional), `create/2`,
  `update/2`, `upsert/4`, `destroy/2`, `authority/1`, `transaction_layer/1`,
  `can?/2` (with `:default`), and the optional `validate_opts/2`,
  `child_specs/1`, `handle_external_change/2`, `handle_external_gap/2`. The
  inbound pair is _defined_ here (so the behaviour module is final and
  `ValidateOrchestrator` checks the full surface) but implemented only in Phase
  4 — stated deferral, not omission.
- `orchestrator` DSL option ({:spark_behaviour, …}, default
  `{ProvenCoverage, []}`); `Info.orchestrator/1` → `{module, opts}`. **DSL-key
  decision (review R5/pass-2 F1 — the gate conflict)**: the strategy-specific
  section keys (`ledger_max_entries`, `divergence_sampler`,
  `local_evaluation?`/`_overrides`, `fold_aggregates?`/`_overrides`,
  `sql_join_aggregates?`/`_overrides`) are **retained as section-level aliases
  in Phase 1**, forwarding into ProvenCoverage opts — existing resource
  declarations and DSL tests compile and pass unchanged, preserving the
  pure-refactor gate. The alias removal (declarations rewritten to orchestrator
  opts, DSL tests updated, deprecation path decided) happens in **Phase 4a**,
  the designated behaviour-change phase. `Info` getters re-route through
  `orchestrator/1` immediately so call sites need not all change at once.
- `Orchestrator.ProvenCoverage`: the whole `run_query/2` tree, aggregate
  dispatch, remainder/merged/source reads, backfill policy, and `WriteDispatch`
  (demoted to a private helper) move in. Kill-switch consultation moves in with
  them (shell no longer short-circuits).
- Shell (`AshMultiDatalayer.DataLayer`) keeps: DSL section, `Query` struct +
  build-callback accumulation, SqlPassthrough second-heads (gated on the
  orchestrator declaring support), structural callbacks as thin delegations to
  `authority/1`/`transaction_layer/1`/`can?/2`, unconditional `false` for
  joins/combinations/bulk-atomic, `Migration`.
- `ValidateOrchestrator` verifier (module implements behaviour; invokes
  `validate_opts/2`); every existing strategy-specific verifier gains the
  `Info.orchestrator/1` no-op guard.
- Forward-compat for
  [stacked orchestrators](../design/20260705-stacked-orchestrators-rfc.md)
  (design recorded, implementation NOT in this arc): **ProvenCoverage's** access
  to the far side of its boundary (source reads/writes — the 7 positional
  `List.last`/`hd` sites review pass 1 located) is funneled through **one
  internal function per direction**. LocalOutbox does not exist until Phase 4,
  so its target-flush funneling is necessarily a Phase 4 act — after Phase 1
  only ProvenCoverage is stacking-ready (review D6). Funneling only; no port
  abstraction is built now.
- **Supervisor discovery mechanism** (review D1/R6, now specified):
  ProvenCoverage **keeps today's lazy start** — table owners spawn on first use;
  its `child_specs/1` returns the existing TableSupervisor arrangement, and no
  resource discovery is needed for it. Eager discovery exists only for
  strategies that require boot-time work (LocalOutbox hydration):
  `AshMultiDatalayer.Supervisor` accepts `otp_app:` (reads the standard
  `config :my_app, ash_domains: [...]`, enumerates
  `Ash.Domain.Info.resources/1`, groups by `Info.orchestrator/1`) or an explicit
  `resources: [...]` — the Phase 3 installer emits the `otp_app:` form. In Phase
  1 this is plumbing only: with just ProvenCoverage configured, behaviour is
  identical to today (lazy).
- **Transitional capability note** (review-2 R6): Phase 1 deliberately keeps the
  shell's existing hardcoded `can?` falses and intersections verbatim — the
  behaviour ADR's "the shell hardcodes no capability answers" end-state arrives
  in **Phase 4a**, exactly like the inbound callbacks arrive in Phase 4. Stated
  deferral, same pattern.

**Gate**: the real suite (~97 unit/property tests at `b290e0d` per pass-3 R1 —
B2 first caught the wrong "~126", counted 85 pre-hardening; count method:
whatever `mix test` reports at the branch commit, recorded so the number is
reproducible, review-3 V3) **plus the `INTEGRATION=1` suite** green **without
modification**; `example/todo_client` and `todo_server` compile and their e2e
passes unchanged; `git diff --stat` on `test/` is empty except for any new
orchestrator-behaviour unit tests. **Funneling auditability** (review D4): the
Phase 1 commit message carries a mapping table — each old positional site
(`List.last`/`hd` at its file:line) → the funnel function that replaced it — so
the behaviour-identical claim is auditable rather than aspirational.

**Status: complete.** Behaviour-identity proven against a _controlled baseline_
(base lib + the concurrent property-test additions, isolating a collaborator's
in-flight work): baseline and refactor both give **88 passed / 73 excluded**
unit and **161 passed** integration — an exact match. Landed: the
`AshMultiDatalayer.Orchestrator` behaviour (13 callbacks) + `ProvenCoverage`
default; the `orchestrator` DSL key with section-alias forwarding through
`Info.orchestrator/1`; `ValidateOrchestrator` + `Info.proven_coverage?/1` no-op
guards on the three strategy-specific verifiers; the `read_source_layer/1` /
`write_authority_layer/1` boundary funnels; and the Supervisor `otp_app:` /
`resources:` discovery plumbing (ProvenCoverage stays lazy → `child_specs/1`
returns `[]`). New unit coverage:
`test/ash_multi_datalayer/orchestrator_test.exs` (12 tests). The positional-site
→ funnel mapping table is in the commit message.

### Phase 2 — Oban + ash_oban + SQLite walking skeleton (spike, kept as tests)

**Objective**: de-risk every third-party assumption in one thin vertical slice
_before_ building on it. Not throwaway: it lands as
`test/integration/oban_sqlite_skeleton_test.exs` + a test-support repo.

**Deliverables** — a scratch Ash domain with one ash_sqlite resource carrying an
ash_oban trigger, running on Oban Lite over a temp SQLite file, proving:

1. ash_sqlite resource + migration codegen against the pinned versions (ash 3.29
   compat).
2. Trigger with `where`/`sort` + `scheduler_cron` sweeps; `run_trigger/3`
   immediate path; `worker_read_action` re-check semantics ("trigger no longer
   relevant" path).
3. `max_attempts` exhaustion invoking `on_error` (the park path), and an
   in-action state transition completing the job without retries (the rejection
   path).
4. `Oban.pause_queue/resume_queue` semantics under Lite: paused queue
   accumulates, resume + `AshOban.schedule/3` drains; in-flight job runs to
   completion across a pause.
5. Snooze confirmation (answer pre-verified, review F11):
   `AshOban.Errors.SnoozeJob` → `{:snooze, seconds}` → engine `snooze_job`
   (re-schedule + `max_attempts` increment = zero budget burn). One test.
6. Unique-job behaviour on Lite (dedupe of concurrent `run_trigger` calls).
7. ash_sqlite keyset streaming for the scheduler — behavioural test only (there
   is **no capability flag to check**; keyset rides Ash-level
   filter+sort+limit); else record `stream_with :full_read` as the required
   setting.
8. **Co-commit despite `can?(:transact) == false`** (review F1): ash_sqlite
   hardcodes the capability off, so the predicate is **same Ecto repo**, not the
   Ash capability — prove a raw `Repo.transaction/1` wrapping two Ash action
   calls (local write + entry insert) on an ash_sqlite-backed repo commits/rolls
   back atomically. Also settle the test strategy: `Ecto.Adapters.SQL.Sandbox`
   vs temp-file repo + truncate (Lite + sandbox is a known-awkward combo).
9. **`seq` on SQLite** (review F7): only `INTEGER PRIMARY KEY` autoincrements in
   SQLite — with a uuid `id` PK, `seq` needs a source. **Preference order
   (pass-3 R10): integer PK/rowid first** (unambiguously safe; uuid demoted to a
   secondary identity); `max(seq)+1` inside the enqueue transaction only if the
   uuid PK proves load-bearing AND item 8 confirms strict serialization (it
   reintroduces a write-path race otherwise).
10. Payload round-trip: a record snapshot dumped into a `:map` attribute and
    rebuilt (RFC open question 3) — pick the encoding (embedded resource vs
    dumped-map + struct rebuild vs `:term`).
11. **Named Oban instance end-to-end** (review-2 R1): enqueue into instance B
    while instance A (default `Oban`) also runs — via MDL-owned insertion
    (`Worker.new(args) |> then(&Oban.insert(instance, &1))` against ash*oban's
    generated worker) — and a cron sweep registered in **instance B's** cron
    plugin picking up a missed row, with `scheduler_cron false` on the trigger.
    Also assert (pass-4 P3): **unique-job dedup holds under the MDL-owned
    insertion path** (item 6 generalised — the `unique` config rides the worker
    struct, so `Worker.new/1` \_should* carry it; prove it), and (review-3 V1)
    an enqueue **from a worker running under instance B** routes to B, resolved
    via `job.conf.name`. Proves the R1 mechanism before Phase 3 builds on it;
    asserted-not-proven today.

**Gate**: each numbered item is a passing test or a written answer in this
plan's addendum section; any "no" answer gets a recorded fallback before Phase 3
starts.

**Status: complete.** All 11 items are passing tests in
`test/integration/oban_sqlite_skeleton_test.exs` (18 tests green), answers
recorded in the Addendum. Two findings feed Phase 3/4: (a) ash_oban's `on_error`
does not fire for generic-action triggers → the flush action self-parks at its
last attempt; (b) `scheduler_cron false` generates no scheduler → sweeping is
MDL-owned (the four-enqueue-site design stands, unchanged).

### Phase 3 — sync-state resource extension + igniter generators

**Objective**: the `AshMultiDatalayer.Sync.OutboxEntry` contract and the
bootstrap path, per the
[sync-state ADR](../design/20260705-sync-state-as-ash-resources-adr.md).

**Deliverables**:

- `AshMultiDatalayer.Sync.OutboxEntry` Spark extension: injects attributes
  (`seq` per Phase 2 item 9, `write_ref`, `resource`, `tenant`, `record_pk`,
  `op`, `payload`, `base_image`, `remote_snapshot` — these three typed **per
  Phase 2 item 10's encoding decision** (review D8) — `target`, `state`,
  `error_class`, `last_error`, `parked_at`, timestamps), actions (`enqueue`,
  `flush`, `park`, `retry`, `discard`, `pending`/`parked`/ `for_record` reads),
  the ash_oban `:flush` trigger (queue/max_attempts from the
  `outbox_entry do ... end` section), the library notifier feeding the `await/2`
  registry, and a verifier that the host resource's data layer is SQL-backed +
  AshOban extension present.
- `Mix.Tasks.AshMultiDatalayer.Install` (igniter): supervisor into the app tree,
  formatter config — subsumes what the README currently asks users to do by
  hand.
- `Mix.Tasks.AshMultiDatalayer.Gen.Outbox` (igniter): generates sync domain +
  outbox resource in the host app; composes `ash_oban.install` (it exists in the
  package: `mix/tasks/ash_oban.install.ex`) and ash_sqlite repo/config setup
  when missing; emits the Oban config block (Lite engine on the shared repo,
  cron plugin, the queue) and prints the `orchestrator` DSL snippet.
- The flush action's _body_ is library code (`LocalOutbox.Flush.run/2` called
  from the generated action) so fixes ship in the library, not in generated user
  files.
- `oban_instance` option on the `outbox_entry` DSL section + orchestrator opts,
  default `Oban` — **committed scope, not contingent** (review F3), with the
  mechanism specified (review-2 R1, since **ash_oban 0.8.10 hardcodes the
  default instance on every enqueue path** — facts): **MDL owns its Oban
  touchpoints — one enqueue helper, four call sites** (pass-4 P1 enumerates
  them; the last two are the non-obvious, library-internal ones an implementer
  would otherwise route through `AshOban.run_trigger/3` and silently hit the
  default instance):
  1. the **immediate kick** on the write path;
  2. the **sweeper** — an MDL-owned sweep worker registered in the instance's
     cron plugin (`scheduler_cron false` on the trigger; emitted by the
     generator's Oban config block);
  3. the **chain continuation** inside `LocalOutbox.Flush.run/2` (success kicks
     the next pending entry of the PK chain);
  4. the **retry re-trigger** in the `retry` resolution path (parked → pending +
     re-enqueue). The helper builds the job against ash*oban's generated worker
     (`worker_module_name` is mandated, so the module is known) and inserts via
     `Oban.insert(instance, job)` — keeping telemetry and unique-job args
     uniform across all four sites even in single-instance deployments. The
     caller-side sites (1) resolve the instance from the same process-scoped
     establishment as the dynamic repo (review-3 V1: the instance plug/hook sets
     both); the worker-side sites (2, 3, 4 — review-4 W2: the sweeper is itself
     a cron-inserted job, so it resolves the same way) from `job.conf.name` —
     established as **`LocalOutbox.Flush.run/2`'s first act** (pass-5 N2: the
     flush \_worker*'s `perform/1` is ash*oban-generated and not injectable; MDL
     owns the \_action body* the worker dispatches to, and pass-5 verified
     generic-action triggers do no read before the action, so `Flush.run/2`
     genuinely is the first Ash call in the worker). pause/resume and queue
     introspection already take the instance as their first argument. ash_oban
     still provides the worker/trigger/action machinery — MDL bypasses only its
     insertion calls. Phase 2 item 11 proves this end-to-end first. **ADR
     qualification** (pass-4 P2): the sweep worker is a thin scheduler of
     pending-entry discovery ("query the outbox resource + insert jobs") — a
     deliberate, named exception to the sync-state ADR's "the library ships no
     queue, no drainer, and no scheduler of its own", forced by ash_oban's
     default-instance hardcoding; the ADR carries the matching footnote.

**Gate**: generator runs green inside a scratch mix project in
`test/support/tmp` (igniter has test harness helpers for this); generated
resource compiles; extension verifier rejects a non-SQL data layer and a missing
AshOban extension with clear messages; unit tests for every injected action.
**Runtime-wiring checks** (review R9 — compilation catches none of these):
re-running the installer/generator is idempotent (no duplicated config,
formatter entries, supervisor children, migrations, or resources); the generated
repo boots against a temp SQLite file with Oban Lite migrated and a job
round-trips; the generated Oban queue/cron config matches the generated
trigger + MDL sweep worker.

### Phase 4 — `Orchestrator.LocalOutbox`

**Objective**: the strategy per the
[RFC](../design/20260705-local-outbox-orchestrator-rfc.md), **without modifying
the shell's data-path code** (the ADR's validation criterion).

**Deliverables** (RFC is normative; this is the checklist):

- Read path: local-only `read/2`/`run_aggregate_query/3`; `authority/1` =
  `transaction_layer/1` = local; `can?/2` per the RFC's inversion.
- Write path: local write → entry-per-target `enqueue` → `outbox_ref` metadata →
  post-commit `run_trigger` kicks. **Co-commit predicate: same Ecto repo**
  (local layer's repo == outbox resource's repo, detected once at verify time)
  wrapped in a raw `Repo.transaction/1` — NOT gated on `can?(:transact)`, which
  ash_sqlite hardcodes false (review F1; facts). Internal atomicity needs the
  repo, not the Ash data-layer capability; caller-visible `can?(:transact)`
  stays the local layer's honest answer. Upstream nicety (not a dependency of
  this arc): propose real `:transact` support to ash_sqlite.
- Flush body: chain-head check on `seq`; PK-upsert/destroy via `Backfill`; error
  triage — offline-class → snooze (zero budget burn, RFC flush outcomes),
  transient → raise/retry, rejection/conflict → immediate park; success deletes
  entry + kicks next chain entry **through the Phase 3 MDL enqueue helper, never
  `AshOban.run_trigger/3`** (pass-4 P1 — same for `retry/1`'s re-trigger; a bare
  run_trigger lands in the default instance and stalls the chain in
  multi-instance deployments);
  `conflict_detection: :off | {:stale_check, field}` incl. the create-collision
  case.
- API: `await/2` (notifier-registry bridge; initial state from a read so no
  transition is missable), `status/1`, `pending/2`, `parked/2`, `retry/1`,
  `discard/1` (create-discard drops the chain, loudly), `discard_local/1`,
  `force/1`, `rebase/2` (re-enters the full write path), `pause_sync/1`,
  `resume_sync/1`, `sync_paused?/1`, `hydrate/2` with the outbox-not-empty
  guard.
- Hydration modes `:if_empty | :on_start | :manual` under `child_specs/1`.
- Inbound: `refresh/3` (pk | `:all` in v1; filtered scope per RFC open
  question 6) with the **dirty-chain rule** (skip PKs with non-empty chains;
  dirty-check + local upsert in one transaction on the co-commit stack,
  serialised through the strategy process on non-transactional local layers);
  `handle_external_change/2` → refresh-that-PK, `handle_external_gap/2` →
  `refresh(:all)` reconcile including the deletion sweep. ProvenCoverage gets
  the same callbacks implemented over its _existing_ invalidation/drop paths
  (aligns with the C4 fold-back work — the evict-on-destroy **and
  evict-on-update + reconcile** machinery, per the C4 addendum's update-variant,
  returns to MDL via the fix plan).
- Kill switch = synchronous write-through per the RFC (drain chain inline →
  replica first → local; parked stays parked).
- LocalOutbox's own `can?/2`: wholesale delegation to the **local layer** for
  everything read-shaped (it is authoritative and complete — aggregates,
  `aggregate_filter`, `distinct`, joins answer whatever the local layer
  answers); write features from the local layer + verify-time check that each
  target accepts PK-upsert/destroy; hardcoded `false` only for the
  orchestration-bypass set (`update_query`/`destroy_query`/`{:atomic,_}`/ bulk —
  they would mutate the local layer without enqueueing), each with the reason in
  a comment. **Transitional note** (review-2 R6): some of these answers are
  masked until Phase 4a removes the shell's blanket falses — Phase 4's gate does
  not exercise joins; the answers go live with 4a.
- Verifiers (strategy-keyed, per Phase 1's mechanism): order shapes, outbox
  contract, deps present, stale-check field trackable, single-node, and
  (review-2 R7) **explicit rejection of multitenant resources whose local layer
  cannot isolate tenants** (ash_sqlite answers `can?(:multitenancy) == false`) —
  a verify-time message instead of a puzzled runtime `false`.
- Telemetry: `[:ash_multi_datalayer, :outbox, ...]` transitions +
  queue-depth/oldest-entry-age; `mix ash_multi_datalayer.inspect` outbox
  section.

**Gate**: deterministic suite with a failing/blocking wrapper layer (extend
`test/support/` per the fix plan's `blocking_layer.ex`) covering: per-PK FIFO
under interleaving and retries, chain-block on park, every resolution verb,
pause/resume accumulation + drain, **two separately-named crash-window tests
(review R8 — do not re-fuse): (a) co-commit atomicity — no crash can leave a
committed local row without its outbox entry (pins Phase 2 item 8's primitive in
strategy context); (b) post-commit kick recovery — a committed entry still
drains when the process dies before/during the job insert (the sweep path)**,
crash-recovery matrix rows from the RFC's durability table, kill-switch
inversion, `await/2` race (park lands before subscribe), refresh vs
concurrent-local-write interleaving (dirty rule holds under races),
gap-reconcile deleting locally what vanished remotely while sparing dirty PKs.
Property test: random op sequences per PK against a chaos target layer converge
— replica equals local once the outbox drains empty, under `:off` and
`{:stale_check, _}` with no concurrent remote writers. **Seam gate** (the ADR's
validation criterion, review F2): the Phase 4 diff touches no shell data-path
code — checkable by inspection because everything shell-side lands in Phase 4a
instead.

### Phase 4a — shell increments + capability derivation

**Objective**: the deliberate shell/ProvenCoverage behaviour changes that must
NOT ride Phase 1 (pure-refactor gate) and must not blur Phase 4's clean-seam
diff (review F2). Two workstreams, separately gated commits.

**Deliverables — per-action layer targeting** (RFC "Per-action layer
targeting"):

- Shell-level `read_from:` context bypass — side-effect-free (no
  recording/backfill/LRU touch), works for any strategy, `[:read, :forced]`
  telemetry.
- `write_through: true` changeset context — passed through to the orchestrator:
  LocalOutbox reuses the kill-switch write path for one action (incl. inline
  chain drain); ProvenCoverage no-op.

**Deliverables — capability derivation** (the "can? answers whatever the
underlying layers support" rework; drivers: the ash_sqlite capability facts
above, implementation-review N10, and the aggregate-filter crash finding):

- The shell's `can?/2` hardcodes and blanket intersections move into the
  strategies; the behaviour's `:default` is redefined as the documented
  per-feature-class derivation. Hardcoded `false` survives **only** as
  bypass-guards (`update_query`/`destroy_query`/`{:atomic,_}`/bulk/ `:combine`;
  joins under ProvenCoverage), each with its reason in a comment — notably these
  stay false even when the layer says true (ash_sqlite answers true to
  `update_query`).
- ProvenCoverage re-derivation: **authority-only** answers for source-executed
  features — `{:lock,_}` (**decision — demanded by pass-3 R3 (which was neutral:
  "pick one"), direction per N10: the lock branch is resurrected, not removed**
  — `can?({:lock,_})` becomes the authority's answer, locked reads route to the
  source, and the newly-live path gets its own test; "answer false and delete
  the branch" is rejected because a source that supports locking should not lose
  the feature to the cache's inability), `:transact` (today's write-intersection
  contradicts `transaction/4`, which already delegates to the authority alone),
  and `:select` (unchanged, already authority-only). `:aggregate_filter` /
  `:aggregate_sort` → explicit `false` (clean refusal; today filtering on a
  foldable aggregate crashes with `KeyError __ash_bindings__` —
  implementation-review M3, reproduced there; the 4a gate test is its first
  committed assertion). `:multitenancy` stays the all-layers intersection — a
  layer that cannot isolate tenants would leak data; that hardening is
  load-bearing.
- **Per-query serving degradation**: read-expressiveness features answer from
  the authority; before serving a covered read, the router checks the cache
  layer can execute the query's actual shape and falls through on a gap. This is
  **new machinery following the `Capability` module's pattern** (review-2 R4 —
  `Capability` today probes only expression evaluability from two call sites;
  the full query-shape check does not exist yet), and it runs **on the
  covered-read hot path** (pass-3 R2), so it carries a cost bound: the check is
  structural — O(query shape: set fields → `can?` calls), never O(data), no
  allocation-heavy normalisation — and the 4a gate asserts the covered-read
  probe overhead stays within the same budget discipline as Phase 5 (measured
  against today's `covers?` probe). This is what lets `can?` stop being the
  pessimistic intersection without ever executing a query on a layer that can't
  run it.
- Write features: authority-only + verify-time check that every propagation
  target supports `:upsert` + `:destroy` (all they ever receive via `Backfill`)
  — the same rule the LocalOutbox RFC already states, generalised.

**Gate**: `read_from:` purity (counting/wrapper layer asserts zero
ledger/outbox/backfill side effects); `write_through:` drains the chain before
the direct write and fails atomically on replica error. Capability tests: a
differential sweep asserting every `can?` answer against a matrix of layer pairs
(ETS/sqlite/postgres/remote) with each answer traceable to a rule above; the
**resurrected lock path** serves a locked read from the source when the
authority supports locking (and `can?({:lock,_})` is the authority's answer —
review R3's decision); aggregate-filter queries refuse loudly; covered-read
probe overhead within budget (pass-3 R2, measured vs today's `covers?`); the
Phase 1 DSL aliases are removed here with the declaration/test updates
enumerated in the commit; existing suite green (behavioural deltas are expected
here and each one is asserted, not discovered).

### Phase 5 — ProvenCoverage ledger as an Ash resource

**Objective**: the ledger's _storage_ behind the same resource pattern —
uniformity, inspectability, user hooks — without regressing the read probe.

**Deliverables**:

- `AshMultiDatalayer.Coverage.LedgerEntry` extension (ETS-backed default
  resource shipped in the library so zero-config keeps working;
  `ledger_resource` opt + `...gen.ledger` generator for apps that want to own it
  — e.g. to subscribe to eviction).
- `Coverage`'s storage primitives (`insert/entries/drop/reset/size/touch`)
  re-routed through the configured resource; `Normaliser`/`Implication`/
  `Complement`/`Entry` term shapes unchanged (attributes typed `:term` where
  needed — probe structures are node-local by design, same as today).
- Benchmark: `covers?` probe + `record` micro-bench (existing ETS path vs
  resource path) committed under `bench/`.

**Gate**: full suite green; benchmark shows probe overhead within **2× of the
raw-ETS baseline and absolutely < 50µs p99** on the dev box (numbers to be
ratified at review) — otherwise the raw-ETS fast path stays as the default
implementation behind the same seam and the resource port ships as opt-in only.
Honesty gate: the plan does not assume the benchmark passes.

### Phase 6 — fold `ash_remote_cache`'s library into ash_remote

**Objective**: dissolve the `ash_remote_cache` _library_ (~480 lines): the
notifier + lifecycle guard move into **ash_remote itself** as user utilities
over the new inbound callbacks. **Deliberately no product name** (user decision
2026-07-05) — they are just utilities ash_remote ships for users composing it
with ash_multi_datalayer. Work happens in the `../ash_remote` repo; this plan
carries the scope so sequencing stays visible.

**Deliverables**:

- MDL side (already built in Phase 4): `handle_external_change/2` /
  `handle_external_gap/2` reachable via `Info.orchestrator/1` dispatch — the
  utilities need zero strategy knowledge.
- ash_remote gains the two utilities (namespace settled in ash_remote review;
  working shape: `AshRemote.MultiDatalayer.ChangeNotifier` + `.LifecycleGuard`):
  the notifier forwards each realtime notification to
  `handle_external_change/2`; the guard forwards `:resubscribed`/ `:join_denied`
  to `handle_external_gap/2`. MDL is an **optional dependency** of ash_remote
  (runtime-checked, like MDL's own optional ash_postgres) — the utilities
  compile away or raise clearly without it.
- The before-image point-query moves out of the notifier into ProvenCoverage's
  `handle_external_change/2` implementation (it is strategy logic, not
  transport). Keep the compile-time-literal `notifiers:` gotcha documented
  wherever the utilities are documented.
- **All five `lib/` modules accounted for** (review F4), not just the two
  headline ones:
  - `InvalidationNotifier` → ash_remote utility calling
    `handle_external_change/2` (before-image point-query moves into
    ProvenCoverage's callback).
  - `LifecycleGuard` → ash_remote utility calling `handle_external_gap/2`.
  - `CacheLayer` (149 lines — the largest module): `evict!/3` + evict-on-destroy
    retire against the fix plan's MDL-native evict-on-destroy/-update +
    reconcile (C4 addendum); `fetch/3` (before-image) moves into
    ProvenCoverage's callback impl.
  - Top-level `AshRemoteCache`: `forget!/3` + `not_found?/1` — promoted to MDL
    public API per the C4 fold-back agreement; `notifiers/1` + `ordered?/1` (the
    RealtimeBridge-runs-after-invalidation ordering guarantee) → ash_remote
    alongside the utilities, since users still need the ordering helper once the
    notifier moves.
  - `Info` (eligibility check) → absorbed into the utilities' own guards or
    retired if `Info.orchestrator/1` dispatch subsumes it — decided in the
    fold-in review.
- Leave a **breadcrumb in the ash_remote_cache repo** (review F10): its
  moduledocs present `evict!/forget!` as permanent fixes; mark them as
  stopgaps-to-retire pointing at MDL's C4 addendum retirement list, since Phase
  6 executes in that repo likely under a fresh context.
- `ash_remote_cache`'s `lib/` is deleted; the repo keeps only the example (which
  Phase 7 builds out) — whatever the repo eventually becomes stays unnamed for
  now. (Path-dep note, review F10: ash_remote_cache and its example pin all
  sibling repos as path deps — changes are picked up live, no pin bump exists or
  is needed there; MDL's own example is the one with the git-ref pin.)

**Gate**: the utilities' tests (moved from ash_remote_cache, including the
invalidation-wiring test) green in ash_remote against extracted MDL, with
**both** reactions exercised: a ProvenCoverage resource invalidates on
notification / drops on gap; a LocalOutbox resource refreshes on notification /
reconciles on gap.

### Phase 7 — the flagship example: collaborative todos, mixed strategies, offline-first

**Objective**: build out `../ash_remote_cache/example` (already the richest
example: ash_authentication with JWT sessions, owner-or-public policies,
realtime socket + client bridge, counting-router tests) into **the** example of
the whole stack — real Phoenix apps, every strategy in its natural role, and the
full conflict-resolution UI. MDL's own `example/` pair stays as the minimal
MDL-only demo.

**Scaffold decision, stated as such** (review F5): the existing apps are
hand-rolled minimal Phoenix (single hand-written `endpoint.ex`, no `*_web`
namespace, no telemetry) — moving to `phx.new` is a **scaffold rewrite plus
wiring migration** (resources, auth plumbing, routers, three test suites
ported), not a "build-out". We take it deliberately: the conventional layout is
what the igniter generators target (the example doubles as an install-path
test), Oban Web mounts into a standard router, and the flagship should look like
the apps users actually have. Cached `phx_new` 1.8.x; client generated
`--database sqlite3`; both `--no-assets` per the offline constraint in the
facts. **LiveView JS without a bundler** (review F5): phoenix/phoenix_live_view
ship servable prebuilt JS and the existing todo_client Live UI already runs on
exactly that — carry its static-path/LiveSocket wiring over rather than
rediscovering it.

**Two-instance mechanism, stated** (review F3): one BEAM cannot boot the same
OTP app twice, so the client app's supervision tree is parameterized — instance
config carries the SQLite file path, the named Oban instance (Phase 3's
`oban_instance` opt), endpoint port, and PubSub name; the app's `start/2` builds
children from it, and the e2e boots two trees via `start_supervised` with
distinct configs (the OTP app does not auto-start in test). **Repo-selection
hook, named** (review-2 R2): the repo module is started twice under distinct
`:name`s (standard Ecto dynamic-repo; verified viable — ash_sqlite resolves
per-query `context.data_layer.repo` overrides and ecto_sqlite3 has no adapter
singleton). `put_dynamic_repo/1` is **per-process and not inherited** (review-3
V1), so every process class gets an explicit establishment point:
endpoint/LiveViews via an instance plug/hook — which establishes **both** the
dynamic repo and the instance's Oban name, since the write-path enqueue +
post-commit kick run in the caller's process; **Oban workers via `job.conf.name`
as `LocalOutbox.Flush.run/2`'s first act** (pass-5 N2: the generated worker's
`perform/1` is ash_oban's, not injectable — MDL owns the action body it
dispatches to, verified to be the worker's first Ash call; a producer-spawned
worker starts with an empty process dictionary, so "the instance's own tree" is
not a mechanism); and MDL's strategy processes (refresh, hydrate) via
`child_specs/1` instance config. This is also honest documentation value: it is
what a real multi-profile client would do.

**External dependency note** (review D7): the utility-wiring deliverables below
are contingent on Phase 6's namespace decision, which lands in the ash_remote
repo's own review — if the shape/name changes there, the wiring diff here
changes with it.

**The domain** (grown from the existing collaborative todos, not replaced):

- Server (`todo_server`, real Phoenix app on **ash_postgres**, keeps
  ash_authentication + RPC router + realtime socket):
  - existing `User`, `TodoList`, `Todo` (owner-or-public policies) — `Todo`
    grows `assignee_id` (belongs_to User) and `tag_ids`;
  - `Tag` — shared catalog (name, colour), read-mostly;
  - `Member` — the RPC-exposed projection of `User` (name, colour) for assignee
    pickers;
  - `Comment` — discussion on a todo (author, body, timestamps);
  - `ActivityEvent` — server-generated feed rows ("Ada completed X"), written
    asynchronously by a **server-side ash_oban trigger** on todo changes — the
    honest server-side ash_oban install.
- Client (`todo_client`, real Phoenix app), one resource per strategy bucket —
  the point of the example is that the _same app_ mixes them:

  | client resource            | layers                        | orchestrator                                                      | why                                                                                                            |
  | -------------------------- | ----------------------------- | ----------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
  | `Todo`, `TodoList`         | ash_sqlite + remote           | LocalOutbox (`{:stale_check, :updated_at}`, `hydrate: :if_empty`) | the working set — **must work offline**                                                                        |
  | `Tag`, `Member`            | ETS + remote                  | ProvenCoverage                                                    | shared read-mostly reference — hot cache, realtime-invalidated (the original ash_remote_cache demo, preserved) |
  | `Comment`, `ActivityEvent` | remote only (plain AshRemote) | —                                                                 | **only meaningful online** — live conversation and feed                                                        |

- Offline behaviour matrix (rendered in the UI, asserted in e2e): todos and
  lists fully usable (sqlite, complete copy); tags/members render from the
  warmed ETS cache, a cold miss while offline errors → placeholder chip +
  "reconnect to load"; comments and activity panels disabled behind an offline
  banner. Coming online: outbox drains (badges flip), gap-resync refreshes
  todos, realtime invalidation resumes for the caches, panels re-enable.

**Deliverables**:

- Both apps re-scaffolded as Phoenix projects; client wiring **via the Phase 3
  generators** (the generator is tested by using it): SQLite repo, Oban Lite on
  it, generated sync domain + `OutboxEntry`; ash_oban installed on both sides
  (client: outbox queue; server: activity trigger).
- **Oban Web** mounted at `/oban` on the client (facts: verified
  self-contained + SQLite-friendly): flush jobs, retry/backoff timers, snoozed
  offline entries, the paused queue while offline — the operator half with zero
  custom UI.
- The ash_remote utilities (Phase 6) wired on every cached/local resource:
  invalidation for `Tag`/`Member`, refresh for `Todo`/`TodoList`; the existing
  `RealtimeBridge` LiveView-refetch notifier kept, ordered after them.
- **Full conflict-resolution UI** (first-class deliverable):
  - **Sync center** (`/sync` LiveView): pending entries (op, record summary,
    target, attempt count + next-retry time from the Oban job, snoozed-offline
    marker); parked entries grouped by record with `error_class` chips (conflict
    / rejected / transient_exhausted), the replica error verbatim, and the
    blocked-chain count; global controls — offline toggle, paused banner,
    pending/parked counts, "sync all now".
  - **Conflict modal** (parked `:conflict` chain head): **three-way field-level
    diff** — `base_image` | local record | remote current (live via the
    `read_from: :remote` context read, `remote_snapshot` as the offline
    fallback, with a refresh button); fields classified changed-local-only /
    changed-remote-only / changed-both.
  - **Every resolution verb as a button**: Retry; Force (local wins); Discard
    local (remote wins); and **Merge** — auto-merged fields (single-sided
    changes) pre-resolved, each both-changed field a local/remote/custom picker,
    submit builds the changeset → `rebase/2`, and the modal shows the rebased
    entry syncing.
  - **Rejected parks** (validation/authorization from the replica): error
    verbatim + edit-and-rebase (the todo form prefilled → `rebase/2`), retry,
    discard.
  - **Chain panel**: pending entries queued behind the parked head; discarding a
    parked _create_ warns it drops its N dependents (loud, per the RFC).
  - **Per-row sync badges** wherever todos render (pending spinner / synced
    check / parked warning), via `status/1` + pub_sub on the outbox resource,
    linking into the sync center.
- Per-record "sync now" using `write_through: true` (drains the chain, hard
  server-durability guarantee for one action).
- RPC-counting assertions: LocalOutbox reads 0-RPC always, writes 0-RPC
  synchronously (flush is the only traffic); ProvenCoverage warm hits 0-RPC;
  forced `read_from: :remote` reads exactly 1.
- In-BEAM e2e (two client instances, different users, `:test`-only server dep):
  hydrate → offline writes accumulate (snooze, not park) → online drains →
  collaborator edit conflicts → **every verb exercised through the UI flow** →
  cross-client: A's write refreshes B's sqlite + invalidates B's tag cache;
  dirty-record skip → stale-check park; forced gap → full reconcile incl. a
  server-deleted row vanishing locally → crash/restart resumes from the SQLite
  file (data + outbox + jobs in one file).
- READMEs: the mixed-strategy story (which data gets which strategy and why),
  the one-file-on-disk client stack, boot-offline re-pause pattern, two-instance
  demo instructions.

**Gate**: e2e green; `mix ash_multi_datalayer.inspect` shows ledger + outbox
sections against the running client; README commands verified by running them;
the offline matrix behaviours demonstrated in tests, not just prose.

### Phase 8 — docs closure

- Rewrite README/guides around the orchestrator concept (behaviour ADR
  consequence #4): strategy selection guide (ProvenCoverage vs LocalOutbox —
  authority direction decides; the Phase 7 example's strategy table is the
  worked illustration), LocalOutbox guide (error model, offline, conflicts + the
  resolution UI patterns, inbound refresh + the ash_remote utilities, durability
  matrix), generator docs.
- PRD decision-log rows listed in the two ADRs + RFC "on acceptance" sections.
- Runbook: parked-entry triage (`docs/runbooks/`).
- Update `docs/technical` architecture doc with the shell/orchestrator split
  diagram.

## Open questions (carried from the RFC, owned here)

1. Upsert base-image under stale-check: degrade to `:force` vs reject at verify
   time — decide in Phase 4 review.
2. `await/2` multi-target granularity — all-targets in v1, revisit on demand.
3. Payload encoding — Phase 2 item 10 decides.
4. ~~`oban_instance` opt~~ — **resolved** (review F3): committed Phase 3 scope;
   the two-instance e2e requires it.
5. Ledger benchmark thresholds — ratify at Phase 5 review before coding.
6. `refresh/3` filtered scope (deletion reconcile within a filter needs the
   filter evaluable on both sides of the wire) — v1 ships `pk | :all`; decide
   the filtered form in Phase 4 review (RFC open question 6).
7. ProvenCoverage refresh-instead-of-invalidate as a bridge reaction (keep the
   cache warm) — explicitly **post-arc**; subtle under at-most-once delivery
   (RFC open question 7). v1 keeps invalidation.

## Addendum: Phase 2 spike answers

Filled in as the walking skeleton lands — one entry per numbered Phase 2 item:
passing test reference, or the recorded answer + fallback.

**Dep resolution (prerequisite to all items).** `ecto_sqlite3` was bumped from
the plan's original `≤0.22.0` to **0.24.1**: 0.22.0 constrains `decimal` to
`< 3.0` (CVE-affected), incompatible with
`ash 3.29.3 → ecto 3.14 → decimal ~> 3.0`. hex.pm became reachable and the user
authorised the update. Locked: oban 2.23.0, ash_oban 0.8.10, ash_sqlite 0.2.17,
ecto_sqlite3 0.24.1, exqlite 0.38.0 (transitive), decimal 3.1.1 (unchanged,
patched). All `optional: true` in the library's `mix.exs`; the library's own
test env compiles them. `mix compile` clean.

**Status: complete.** The skeleton lands as
`test/integration/oban_sqlite_skeleton_test.exs` (18 tests, all green; tagged
`:integration` + `:oban_sqlite`) plus test support under
`test/support/oban_sqlite/` (`SkeletonRepo`, `SkeletonRepoB`, `SkeletonDomain`,
`Entry`, `Migrations`, `Probe`). Per-item answers:

1. **ash_sqlite resource + codegen** — CRUD round-trips through Ash on
   ecto*sqlite3 (ash 3.29.3 compat);
   `AshSqlite.MigrationGenerator.generate(..., dry_run: true)` emits
   `create table "amd_skeleton_entries"` DDL. \_Tests: item 1.*
2. **Trigger + immediate path** — `AshOban.run_trigger/2` enqueues,
   `drain_queue` runs the generic `:flush` action. The scheduler `where`/sort is
   exercised via the **MDL sweep** pattern (read the keyset-paginated `:pending`
   action, insert a flush job per row) — see finding below. _Tests: item 2._
3. **Park paths** — a rejection parks immediately and completes the job (no
   retries). **Finding: `on_error` does NOT fire for generic-action (`:action`)
   triggers** — ash*oban wires `handle_error` (the on_error/park path) only into
   the update/destroy `perform`, not the `:action` one (`define_schedulers.ex`:
   generic `perform` rescue at ~1072 just `check_for_oban_return |> reraise`;
   `handle_error(job, …)` is called only at the update/destroy rescues
   ~841/1207/1324). **Consequence for Phase 4:** the flush action must
   **self-park at its last attempt** (`job.attempt >= job.max_attempts`) rather
   than declaring `on_error :park`. \_Tests: item 3.*
4. **`job.conf.name`** — readable in the generic action body via
   `context[:ash_oban][:job].conf.name`; generic triggers do no read first, so
   the action is the worker's first Ash call (the sound establishment point).
   _Tests: items 4, 11._
5. **Snooze** — `raise AshOban.Errors.SnoozeJob, snooze_for: n` →
   `check_for_oban_return` → `{:snooze, n}` → Lite reschedules the job **and
   bumps `max_attempts`** (zero retry-budget burn — asserted on the `oban_jobs`
   row). _Tests: item 5._
6. **Unique jobs on Lite** — the generated worker carries
   `unique: [period: :infinity, states: incomplete]`; two identical
   `Worker.new/1` inserts dedup to one row (same job id) under the MDL-owned
   insertion path. _Tests: items 6, 11._
7. **Keyset streaming** — the trigger's `read_action` **must** support keyset
   pagination (compile-time error otherwise). Keyset pagination over the
   `:pending` read works on ash*sqlite (`page: [limit: n]` → `Ash.page!(*,
   :next)` in seq order). There is no ash*sqlite capability flag; keyset rides
   Ash-level pagination. \_Tests: item 7.*
8. **Co-commit** — `AshSqlite.DataLayer.can?(_, :transact) == false`, yet a raw
   `SkeletonRepo.transaction/1` wrapping two Ash writes commits/rolls back
   atomically. Co-commit predicate = **same Ecto repo + raw
   `Repo.transaction/1`**, never the Ash capability. **Test strategy settled:**
   temp-file SQLite + `async: false` + truncate-between-tests (NOT
   `Ecto.Adapters.SQL.Sandbox` — the ecto*sqlite3 adapter documents Sandbox as
   single-writer-awkward, and a temp file lets a drained worker in another
   process see the same DB). \_Tests: item 8.*
9. **`seq`** — `integer_primary_key :seq` → SQLite `INTEGER PRIMARY KEY`
   (rowid), monotonically autoincrementing; `ref` (uuid) demoted to a secondary
   identity. Decision: **integer PK/rowid** (no `max(seq)+1` needed). _Tests:
   item 9._
10. **Payload encoding** — a record snapshot stored in a `:map` attribute
    round-trips through SQLite JSON intact for JSON-safe values (strings,
    numbers, bools, nested maps/lists). Decision: **dumped-map in a `:map`
    attribute** (string keys); embedded/`:term` not needed for v1. _Tests:
    item 10._
11. **Named instance (the R1 mechanism)** — proven with **two isolated SQLite
    files** (A = resource+Oban, B = its own `oban_jobs`), the real two-profile
    shape. MDL-owned insertion (`Oban.insert(instance, Worker.new(args))`) into
    B runs under B and the action sees `job.conf.name == B`;
    `AshOban.run_trigger` lands in the **default** instance only and B never
    sees it (the R1 gap that forces MDL to own its four insertion sites); unique
    dedup holds under B. `scheduler_cron false` → **no scheduler module is
    generated** (so `AshOban.schedule/2` is unavailable — confirming sweeping
    must be MDL-owned). _Tests: item 11._

## Links

- [Critical-bugs fix plan](./critical-bugs-fix-plan.md) — Phase 0 gate.
- [Orchestrator behaviour ADR](../design/20260705-orchestrator-behaviour-adr.md)
- [Sync-state-as-Ash-resources ADR](../design/20260705-sync-state-as-ash-resources-adr.md)
- [LocalOutbox RFC](../design/20260705-local-outbox-orchestrator-rfc.md)
- [No-write-behind-in-v1 ADR](../design/20260417-no-write-behind-in-v1-adr.md)
- [Stacked-orchestrators RFC](../design/20260705-stacked-orchestrators-rfc.md) —
  exploratory, post-arc; Phase 1's funneling note is its only footprint here.
- [Partial-serving plan](./partial-serving-remainder-reads-plan.md) — format
  precedent; its "gate + property suite per proof obligation" discipline applies
  here unchanged.

---

**Last Updated**: 2026-07-05
