# `ash_multi_datalayer` — Task Index

Tasks are numbered in implementation order. Each task is one PR (~800 LOC max).
Sizes: **S** < 4 hours, **M** 0.5–1 day, **L** 1–2 days. Larger items are
decomposed below.

Mapped to phases in [the plan](../../plans/ash-multi-datalayer-plan.md).

## Phase 1 — Deps + stub

| #   | Task                                                                | Size | Depends on |
| --- | ------------------------------------------------------------------- | ---- | ---------- |
| 01  | [Scaffold deps in `mix.exs`](./01-scaffold-deps.md)                 | S    | —          |
| 02  | [Supervisor skeleton](./02-supervisor-skeleton.md)                  | S    | 01         |
| 03  | [Stub `AshMultiDatalayer.DataLayer` module](./03-stub-datalayer.md) | S    | 01         |

## Phase 2 — DSL + Info + transformer

| #   | Task                                                                                         | Size | Depends on |
| --- | -------------------------------------------------------------------------------------------- | ---- | ---------- |
| 04  | [`multi_data_layer` DSL section + `Layer` entity](./04-dsl-section.md)                       | M    | 03         |
| 05  | [`AshMultiDatalayer.DataLayer.Info` introspection module](./05-info-module.md)               | M    | 04         |
| 06  | [`RegisterUnderlyingExtensions` transformer](./06-transformer.md)                            | M    | 04         |
| 07  | [Integration test: `mix ash_postgres.generate_migrations`](./07-generate-migrations-test.md) | M    | 06         |

## Phase 3 — Coverage infra + kill-switch

| #   | Task                                                                               | Size | Depends on |
| --- | ---------------------------------------------------------------------------------- | ---- | ---------- |
| 08  | [`Coverage.TableOwner` GenServer + ledger ETS table](./08-coverage-table-owner.md) | M    | 02         |
| 09  | [Runtime kill-switch (`:persistent_term`) API + Mix tasks](./09-kill-switch.md)    | S    | 02         |

## Phase 4 — Read path, single-layer

| #   | Task                                                                            | Size | Depends on |
| --- | ------------------------------------------------------------------------------- | ---- | ---------- |
| 10  | [`run_query/2` routing to single `read_order` layer](./10-read-single-layer.md) | M    | 05, 09     |

## Phase 5 — Implication solver

| #   | Task                                                                            | Size | Depends on |
| --- | ------------------------------------------------------------------------------- | ---- | ---------- |
| 11  | [Filter normalisation to per-attribute interval DNF](./11-filter-normaliser.md) | L    | 01         |
| 12  | [`Coverage.Implication.implies?/2`](./12-implies.md)                            | L    | 11         |
| 13  | [StreamData property suite for the solver](./13-solver-property-suite.md)       | L    | 12         |

## Phase 6 — Coverage-aware reads + backfill

| #   | Task                                                                                    | Size | Depends on |
| --- | --------------------------------------------------------------------------------------- | ---- | ---------- |
| 14  | [`Coverage.record/3` + ledger insertion](./14-ledger-record.md)                         | M    | 08, 12     |
| 15  | [Coverage-aware `run_query/2` (fall-through + backfill)](./15-coverage-aware-reads.md)  | L    | 10, 14     |
| 16  | [Integration tests: subsumption hit / miss / backfill](./16-subsumption-integration.md) | M    | 15         |

## Phase 7 — Row-aware invalidation

| #   | Task                                                                                   | Size | Depends on |
| --- | -------------------------------------------------------------------------------------- | ---- | ---------- |
| 17  | [`Coverage.Invalidation.should_drop?/3` via `Ash.Filter.Runtime`](./17-row-matcher.md) | M    | 14         |
| 18  | [StreamData property suite for invalidation](./18-invalidation-property-suite.md)      | M    | 17         |
| 19  | [Writes dispatcher + ledger invalidation](./19-writes-dispatcher.md)                   | L    | 17, 03     |

## Phase 8 — Ledger cap + LRU eviction

| #   | Task                                                                        | Size | Depends on |
| --- | --------------------------------------------------------------------------- | ---- | ---------- |
| 20  | [Cap enforcement + LRU eviction in `Coverage.record/3`](./20-ledger-cap.md) | M    | 14         |
| 21  | [Benchmark `ledger_max_entries` default](./21-ledger-cap-benchmark.md)      | S    | 20         |

## Phase 9 — Divergence sampler

| #   | Task                                                                     | Size | Depends on |
| --- | ------------------------------------------------------------------------ | ---- | ---------- |
| 22  | [Sampler + shadow-read + mismatch telemetry](./22-divergence-sampler.md) | M    | 15         |

## Phase 10 — Verifiers

| #   | Task                                                                                   | Size | Depends on |
| --- | -------------------------------------------------------------------------------------- | ---- | ---------- |
| 23  | [`ValidateLayers` verifier](./23-validate-layers.md)                                   | S    | 05         |
| 24  | [`ValidateMultitenancy` verifier](./24-validate-multitenancy.md)                       | S    | 05         |
| 25  | [`RejectFieldPolicies` verifier](./25-reject-field-policies.md)                        | S    | 05         |
| 26  | [`RejectMultiNode` verifier (warn)](./26-reject-multi-node.md)                         | S    | 05         |
| 27  | [`ValidateSolverSupportedPredicates` verifier (warn)](./27-validate-solver-support.md) | S    | 05, 12     |

## Phase 11 — Capability negotiation

| #   | Task                                                                                 | Size | Depends on |
| --- | ------------------------------------------------------------------------------------ | ---- | ---------- |
| 28  | [`can?/2` strategy-aware implementation](./28-can-strategy-aware.md)                 | M    | 05         |
| 29  | [Capability matrix test covering all shipped combos](./29-capability-matrix-test.md) | M    | 28         |

## Phase 12 — Debug helpers + Mix tasks

| #   | Task                                                                                   | Size | Depends on |
| --- | -------------------------------------------------------------------------------------- | ---- | ---------- |
| 30  | [`AshMultiDatalayer.Debug.dump_ledger/2` + `explain_covers?/2`](./30-debug-helpers.md) | M    | 14, 12     |
| 31  | [`mix ash_multi_datalayer.{disable,enable,inspect}` tasks](./31-mix-tasks.md)          | S    | 09, 30     |

## Pre-release

| #   | Task                                                    | Size | Depends on |
| --- | ------------------------------------------------------- | ---- | ---------- |
| 32  | [Dogfood in the author's host project](./32-dogfood.md) | L    | 31         |
| 33  | [Publish `0.1.0-rc.1` to Hex](./33-hex-release.md)      | S    | 32         |

---

## Notes on task granularity

- Tasks 01–09 are "infrastructure" — no user-visible behaviour yet. Phase gates
  enforce demonstrability: Phase 2 ships a resource that compiles and works with
  `generate_migrations`; Phase 4 ships a single-layer read; Phase 6 ships the
  first cache hit.
- Property test tasks (13, 18) are sized **L** because generator design +
  cross-check evaluator are not trivial.
- Verifier tasks (23–27) are **S** because each is a focused Spark verifier with
  happy + failure tests.

## Representative task files

Tasks 01, 04, 12, 17, 22 are included as fully-detailed examples (in this
directory). The remaining task files will be expanded as their phases start; the
content above is detailed enough to begin work.
