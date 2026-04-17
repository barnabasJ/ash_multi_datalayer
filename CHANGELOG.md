# Changelog

All notable changes to `ash_multi_datalayer` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Initial implementation of `AshMultiDatalayer.DataLayer` — an `Ash.DataLayer`
  that composes multiple underlying datalayers via generic ordered layering.
- `multi_data_layer do ... end` resource DSL with `layer`, `read_order`,
  `write_order`, `backfill?`, `ledger_max_entries`, and `divergence_sampler`
  options.
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
- **`RegisterUnderlyingExtensions` transformer** — brings each declared layer's
  DSL extension into scope on the resource (so `ets do ... end`,
  `postgres do ... end` continue to work).
- **Debug helpers** — `AshMultiDatalayer.Debug.dump_ledger/2`,
  `explain_covers?/2`, and the `mix ash_multi_datalayer.inspect` Mix task.
- Property-based test suites (StreamData) for the implication solver and
  row-aware invalidation, cross-checked against brute-force / runtime
  evaluators.

### Not in this release (planned for v2+)

- `:write_behind` / Oban integration.
- Multi-node cache coherence.
- `field_policies` compatibility.
- N>2 layer configurations in CI.
- Cache stampede prevention.
- Per-action strategy override.

## [0.1.0] — TBD

Pre-release. The [Unreleased] entries above will be moved here on the 0.1.0 Hex
release.

[Unreleased]:
  https://github.com/barnabasj/ash_multi_datalayer/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/barnabasj/ash_multi_datalayer/releases/tag/v0.1.0
