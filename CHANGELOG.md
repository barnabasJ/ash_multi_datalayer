# Changelog

All notable changes to `ash_multi_datalayer` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Initial implementation of `AshMultiDatalayer.DataLayer` — an `Ash.DataLayer`
  that composes multiple underlying datalayers via generic ordered layering.
- `multi_data_layer do ... end` resource DSL with `layer`, `read_order`,
  `write_order`, `orchestrator`, `ledger_max_entries`, `divergence_sampler`,
  `local_evaluation?`/`local_evaluation_overrides`,
  `fold_aggregates?`/`fold_aggregate_overrides`, and
  `sql_join_aggregates?`/`sql_join_aggregate_overrides` options. (There is no
  `backfill?` option — backfill is always on for multi-layer `read_order`.)
- **Filter-subsumption coverage ledger.** A per-resource ETS table records
  materialised filters; incoming queries served from an earlier layer whenever a
  ledger entry logically implies their filter (per-attribute interval
  representation).
- **Row-aware ledger invalidation.** Writes drop only ledger entries whose
  filter matches the changed row (via `Ash.Filter.Runtime.do_match/2`);
  unrelated entries preserved.
- **Synchronous write dispatch** via `write_order`; fail-fast on the first
  layer, best-effort on subsequent.
- **Strategy-aware capability negotiation** (`can?/2` intersects the layers
  actually named in the relevant `*_order`, so primary-only write configs retain
  primary-layer capabilities like `:transact`).
- **Runtime kill-switch** (`AshMultiDatalayer.enable!/1`, `disable!/1`;
  `mix ash_multi_datalayer.disable|enable` Mix tasks) for bypassing the cache
  layer without recompile.
- **Ledger size cap + LRU eviction** with
  `[:ash_multi_datalayer, :ledger, :evicted]` and `:full` telemetry.
- **Divergence sampler** — configurable fraction of coverage hits shadow-re-run
  against the later layer, emitting
  `[:ash_multi_datalayer, :read, :divergence_detected]` on mismatch.
- **Rich telemetry** —
  `[:read, :hit | :miss | :backfill | :divergence_detected]`,
  `[:write, :applied | :failed_at_layer]`,
  `[:ledger, :invalidated | :evicted | :full]`. Every event carries
  `%{resource, tenant, filter_fingerprint, read_order, write_order}` metadata.
- **Compile-time verifiers**:
  - `ValidateLayers` — ensures at least two declared layers and that all
    `read_order`/`write_order` names are declared.
  - `ValidateMultitenancy` — all declared layers agree on multi- tenancy
    strategy.
  - `RejectFieldPolicies` — rejects resources combining `field_policies` with
    multi-layer `read_order`.
  - `RejectMultiNode` — warns unless the host app sets
    `config :ash_multi_datalayer, :assume_single_node, true`.
  - `ValidateSolverSupportedPredicates` — warns when resource filters
    unconditionally fall through to later layers.
- Underlying-layer DSL sections stay available by listing the layer's extension
  yourself (`extensions: [AshPostgres.DataLayer]` — Spark resolves extensions at
  `use` time, so the library cannot install them); the `ValidateLayers` verifier
  reports any required extension you omitted.
- **Debug helpers** — `AshMultiDatalayer.Debug.dump_ledger/2`,
  `explain_covers?/2`, and the `mix ash_multi_datalayer.inspect` Mix task.
- Property-based test suites (StreamData) for the implication solver and
  row-aware invalidation, cross-checked against brute-force / runtime
  evaluators.
- **Orchestrator behaviour** (`AshMultiDatalayer.Orchestrator`) — the strategy
  seam. The data layer is a thin shell that delegates the data path, structural,
  inbound, and lifecycle callbacks to a per-resource strategy; `ProvenCoverage`
  (the default, the original cache-through behaviour) and `LocalOutbox` are the
  two shipped strategies. `ValidateOrchestrator` verifier.
- **`LocalOutbox` orchestrator** — offline-first / local-authoritative strategy:
  reads are served entirely from a local layer, writes commit locally and
  co-commit an outbox entry that an Oban worker flushes to the replication
  target. Includes conflict parking (`conflict_detection: {:stale_check, field}`
  three-way snapshots), the resolution API
  (`await/status/pending/parked/retry/discard/discard_local/force/rebase`),
  queue control (`pause_sync/resume_sync/sync_paused?`), inbound refresh and
  hydration (`refresh/hydrate`, `hydrate: :on_start | :if_empty | :manual`), and
  per-action targeting via changeset/query context (`read_from:`,
  `write_through: true`).
- **`OutboxEntry` Spark extension + generators** —
  `mix ash_multi_datalayer.install` and `mix ash_multi_datalayer.gen.outbox`
  scaffold the app-owned outbox resource (Ash resource on Oban/ash_oban) and its
  migration.
- **Inbound realtime seam** — the strategy-agnostic
  `AshMultiDatalayer.Notifiers.ExternalChange` notifier routes external change
  notifications (e.g. from `AshRemote.Realtime`) to the resource's orchestrator:
  ProvenCoverage invalidates covered rows; LocalOutbox refreshes the row into
  the local authority, skipping PKs with unflushed local edits (the dirty-chain
  rule). `AshMultiDatalayer.RemoteContext` threads auth/tenant context into
  background pushes.
- **Relationship aggregates** — folded from cached related rows when coverage
  proves them (`fold_aggregates?`, 0 source reads) or passed through to SQL when
  source and destination share a repo (`sql_join_aggregates?`); refusal
  (`AggregatesNotSupported`) only when both toggles are off.
- **Computed-value merge reads + local evaluation** — calculations the cache
  layer can evaluate are computed locally from covered rows
  (`local_evaluation?`); others are merged from one narrow source query.
- **Partial (remainder) reads** — a partially covered filter serves the covered
  part from the cache and fetches only the uncovered remainder
  (`[:read, :partial]` telemetry).
- `AshMultiDatalayer.forget!/3` (per-row purge) and `not_found?/1`.
- Telemetry additions: `[:read, :partial]`, `[:read, :forced]` (the `read_from`
  escape hatch), and the `:calc_sort_source_only` miss reason.

### Fixed

Whole-repo review findings (2026-07-06), all `LocalOutbox`/coverage
correctness or hygiene issues found before any release:

- `LocalOutbox.rebase/2` no longer destroys the outbox entries its own
  resolution write just created — it now captures the parked chain's entry
  IDs before applying the changeset and destroys exactly those, inside one
  outbox-repo transaction. A cleanup failure after a successful apply leaves
  the resolution durably applied locally (its fresh entries held `:blocked`
  behind the still-parked head) and returns a structured
  `RebaseCleanupError` naming the head to resolve, instead of silently losing
  replication.
- `write_through: true` writes now match their documented invariant —
  every replica target is written **first**; the local layer commits only
  once every target has durably accepted the write. A replica failure fails
  the action with the local layer untouched (it previously committed the
  local write first, so a replica failure left an un-replicable local write
  with no outbox entry to repair it).
- `LocalOutbox.Flush.classify/1` gained a third class: `%Ash.Error.Forbidden{}`
  / `class: :forbidden` parks immediately as `:auth` (no retry-budget burn —
  a token does not un-expire by retrying), instead of falling through to the
  `:transient` catch-all and masking an expired credential as flakiness. The
  outbox `error_class` constraint now accepts `:auth` (library upgrade +
  recompile only — no `gen.outbox` re-run, no migration). `drain_chain_inline`
  conflicts now surface as a typed `LocalOutbox.ConflictError`, not a bare
  `{:conflict, remote}` tuple.
- Reconcile's ghost eviction now participates in the invalidation epoch
  protocol (`Invalidation.on_evict/3`, batched per reconcile pass): a
  concurrent reader's coverage entry over a row reconcile is about to evict is
  now correctly dropped in the same batch, closing a race that could leave a
  lasting, silent missing-row cache hit.
- A LocalOutbox config with no co-commit repo between the local layer and the
  outbox resource is now rejected at compile time (`validate_opts`) instead of
  silently degrading to an orphaned local write on the first outbox-enqueue
  failure; a belt-and-suspenders runtime guard also converts a would-be raise
  in that path to `{:error, _}`.
- `discard_local/1` now propagates the local-write result: on failure it
  returns `{:error, _}` and leaves the chain in place, instead of dropping the
  only record of the disagreement while the local layer still holds the
  un-discarded value. A failed `hydrate: :on_start`/`:if_empty` boot hydration
  now logs a warning (mirroring `ExternalChange`'s contract) instead of
  swallowing the failure silently.
- `DataLayer.transaction/4`'s no-transaction-callback fallback now catches the
  `{:rollback, term}` throw its own `rollback/2` fallback raises, returning
  `{:error, term}` instead of an uncaught `nocatch` crash.
- `ExternalChange.notify/1` now catches `:exit`/`:throw` in addition to raised
  exceptions (a `GenServer.call` timeout inside a reaction exits, not raises),
  keeping its "never crash the notifying socket" contract.
- `LocalOutbox`'s flush worker and resolution verbs resolve a persisted
  `resource` string against a cached known-resource map instead of
  `String.to_existing_atom/Module.concat` directly — a stale outbox row
  naming a resource the app no longer defines now parks as `:rejected` (or
  raises a clear message from the manual verbs) instead of crashing on an
  unresolvable atom.
- Documented (doc-only by decision): the narrow window between a write's
  physical eviction and its re-propagation, where a reader can observe a row
  as physically absent even though it existed before and exists again
  immediately after (an absence anomaly, not staleness).

### Not in this release (planned for v2+)

- Multi-node cache coherence.
- `field_policies` compatibility.
- N>2 layer configurations in CI.
- Cache stampede prevention.
- Stacked orchestrators (exploratory RFC only).

## [0.1.0] — TBD

Pre-release. The [Unreleased] entries above will be moved here on the 0.1.0 Hex
release.

[Unreleased]:
  https://github.com/barnabasj/ash_multi_datalayer/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/barnabasj/ash_multi_datalayer/releases/tag/v0.1.0
