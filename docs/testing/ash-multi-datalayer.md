# `ash_multi_datalayer` — Test Strategy

**Status**: Draft **Created**: 2026-04-17 **Last Updated**: 2026-07-03

## Overview

Test strategy for the v1 implementation of `ash_multi_datalayer`. The shape is
**integration-heavy** because the library is a delegating datalayer whose
correctness is defined by the composition of two real underlying datalayers;
most bugs live at the seams.

**Related Documents**:

- [PRD](../design/ash-multi-datalayer-prd.md)
- [Implementation Plan](../plans/ash-multi-datalayer-plan.md)
- [Technical deep-dive](../technical/ash-multi-datalayer.md)

## Testing Model

| Layer       | Definition (this project)                                                 | Scope                                                                                                       | Status  |
| ----------- | ------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- | ------- |
| Unit        | In-process pure-function or GenServer-isolated tests; no DB.              | `Coverage.Implication`, `Coverage.Invalidation`, `Info`, verifiers, kill-switch, telemetry fingerprints     | Planned |
| Integration | Real Postgres (via `ash_postgres` TestRepo), real ETS, compiled resources | `run_query/2`, write dispatch, `mix ash_multi_datalayer.generate_migrations`, ledger + cache + primary interaction | Planned |
| Property    | StreamData-generated cases, cross-checked against a reference evaluator   | Solver implication; row-aware invalidation                                                                  | Planned |
| Manual      | `iex -S mix` smoke in the author's own host project                       | Pre-release dogfood                                                                                         | Planned |

**Model rationale**: the library's headline correctness invariant ("solver bugs
never return stale rows") is only verifiable at the property-test layer; the
integration surface is wide but each test is a small scenario; unit tests cover
pure internals. There is no E2E layer because the library has no user-facing
surface beyond Ash itself.

## Risk-Based Coverage

| Component / Area                                     | Likelihood of Defect | Business Impact      | Test Layers                   | Notes                                                    |
| ---------------------------------------------------- | -------------------- | -------------------- | ----------------------------- | -------------------------------------------------------- |
| `Coverage.Implication` (solver)                      | High                 | High (stale reads)   | Unit + Property + Integration | Highest-priority area. Property suite is mandatory.      |
| `Coverage.Invalidation` (row-matcher)                | High                 | High (stale reads)   | Unit + Property + Integration | Same rigor as the solver; inverse problem.               |
| `AshMultiDatalayer.Migration` shadow modules + migration generator | High                 | High (compile break) | Integration                   | Architect's blocking concern; one dedicated test.        |
| Verifiers (5 of them)                                | Medium               | Medium (UX)          | Unit                          | Each needs both an accept case and a reject case.        |
| Kill-switch                                          | Low                  | Medium (ops)         | Unit + Integration            | Small surface; integration confirms runtime bypass path. |
| Telemetry event shape                                | Low                  | Medium (ops)         | Unit                          | Each event captured in a test; schema verified.          |
| Ledger cap + LRU                                     | Medium               | Medium (mem)         | Integration                   | Benchmark-gated default; test asserts eviction order.    |
| Divergence sampler                                   | Low                  | High (observability) | Integration                   | Seed divergent state; assert telemetry fires.            |
| DSL / Info introspection                             | Low                  | Low                  | Unit                          | Thin wrapper over Spark; small.                          |

## Acceptance Criteria Mapping

| PRD Acceptance Criterion                                                                     | Test Type   | Test Location                                                          | Status  |
| -------------------------------------------------------------------------------------------- | ----------- | ---------------------------------------------------------------------- | ------- |
| Switching `data_layer:` + adding the DSL block compiles with no other changes                | Integration | `test/integration/drop_in_replacement_test.exs`                        | Planned |
| `mix ash_multi_datalayer.generate_migrations` works on a multi-datalayer resource            | Integration | `test/integration/generate_migrations_test.exs`                        | Planned |
| Subsumption recognises `name == "foo"` implies `name == "foo" and age > 18`                  | Integration | `test/integration/subsumption_test.exs`                                | Planned |
| Solver cross-check against brute-force evaluator — 10 k cases, zero counterexamples          | Property    | `test/ash_multi_datalayer/coverage/implication_property_test.exs`      | Planned |
| Row-aware invalidation keeps unrelated ledger entries on writes                              | Integration | `test/integration/row_aware_invalidation_test.exs`                     | Planned |
| Row-aware invalidation cross-check against `Ash.Filter.Runtime.do_match/2`                   | Property    | `test/ash_multi_datalayer/coverage/invalidation_property_test.exs`     | Planned |
| Capability matrix: `can?(:transact)` correct across `(read_order, write_order)` combinations | Unit        | `test/ash_multi_datalayer/capabilities_test.exs`                       | Planned |
| Divergence sampler fires `:divergence_detected` telemetry on seeded mismatch                 | Integration | `test/integration/divergence_sampler_test.exs`                         | Planned |
| Runtime kill-switch bypasses cache layer without recompile                                   | Integration | `test/integration/kill_switch_test.exs`                                | Planned |
| Ledger cap evicts oldest entry on overflow                                                   | Integration | `test/integration/ledger_cap_test.exs`                                 | Planned |
| Verifier rejects `field_policies` + multi-layer `read_order`                                 | Unit        | `test/ash_multi_datalayer/verifiers/reject_field_policies_test.exs`    | Planned |
| Verifier warns on missing single-node ack                                                    | Unit        | `test/ash_multi_datalayer/verifiers/reject_multi_node_test.exs`        | Planned |
| Tenant isolation: cross-tenant filter pairs never claim coverage                             | Property    | `test/ash_multi_datalayer/coverage/tenant_isolation_property_test.exs` | Planned |

## Unit Tests

### `AshMultiDatalayer.Coverage.Implication`

**File**: `test/ash_multi_datalayer/coverage/implication_test.exs`

#### Test Cases

- [ ] **`implies?/2` is reflexive** on normalised filters.
- [ ] **`implies?/2` is transitive** on handwritten triples.
- [ ] Narrower `eq` implies broader `eq` of same attribute.
- [ ] Range subset implies range superset.
- [ ] `in` subset implies `in` superset.
- [ ] `eq` implies `in` when the value is in the list.
- [ ] Disjunction: `(a OR b) implies_by c` iff `a implies_by c` and
      `b implies_by c`.
- [ ] `loaded_fields` subset check: narrower selects implied by broader selects
      only.
- [ ] Unsupported predicate → `false`.
- [ ] Different tenant → `false`.

**Example**:

```elixir
describe "implies?/2 on eq predicates" do
  test "narrower eq implies broader range" do
    cached = normalise(filter(age: [gt: 10, lt: 30]))
    probe  = normalise(filter(age: [eq: 20]))
    assert implies?(cached, probe)
  end
end
```

### `AshMultiDatalayer.Coverage.Invalidation`

**File**: `test/ash_multi_datalayer/coverage/invalidation_test.exs`

#### Test Cases

- [ ] `on_write/5` drops entries whose filter matches `row_after` (create).
- [ ] Drops entries whose filter matches `row_before` (destroy).
- [ ] Drops entries whose filter matches either side (update).
- [ ] Keeps entries whose filter matches neither.
- [ ] Drops conservatively on `:unknown` evaluator result.
- [ ] Cross-tenant write doesn't touch other-tenant entries.

### Verifiers

**Files**: `test/ash_multi_datalayer/verifiers/*_test.exs`

Each verifier needs:

- [ ] Happy-path resource compiles.
- [ ] Failing-path assertion on the expected error text. **Not** via
      `assert_raise`: in spark 2.7 the whole verifier pass is wrapped in a
      catch that converts `DslError`s to compiler warnings/diagnostics (which
      fail builds under `--warnings-as-errors`) — verifier failures do not
      hard-raise at runtime. Instead, tests call the verifier directly on the
      resource's `spark_dsl_config` and use Spark's test collector to capture
      the diagnostics.

### Kill-switch

**File**: `test/ash_multi_datalayer/kill_switch_test.exs`

- [ ] `disable!/1` sets the flag; `enabled?/1` returns `false`.
- [ ] `enable!/1` clears the flag.
- [ ] Unrelated resources are unaffected.

### Telemetry fingerprints

**File**: `test/ash_multi_datalayer/telemetry/fingerprint_test.exs`

- [ ] Structurally identical filters produce identical fingerprints.
- [ ] Filters differing only in literal values produce identical fingerprints.
- [ ] Filters differing in operator produce different fingerprints.
- [ ] Raw literal values do not appear in the default fingerprint
      (PII-regression guard).

## Integration Tests

### Drop-in replacement

**File**: `test/integration/drop_in_replacement_test.exs`

**What it covers**: A resource that previously used `AshPostgres.DataLayer`
directly, when switched to `AshMultiDatalayer.DataLayer` with `read_order [:l2]`
and `write_order [:l2]`, behaves identically.

#### Test Cases

- [ ] Reads return identical rows.
- [ ] Creates produce identical records.
- [ ] Updates + destroys behave identically.

**Setup Requirements**: `TestRepo` with a seeded table.

**Mocking boundaries**: None. Real Postgres, real ETS.

### Migration generator compatibility

**File**: `test/integration/generate_migrations_test.exs`

**What it covers**: Architect's blocking concern — migration tooling must keep
working on multi-datalayer resources. As discovered during implementation, the
stock `mix ash_postgres.generate_migrations` discovers resources via hard
equality (`Ash.DataLayer.data_layer(resource) == AshPostgres.DataLayer`,
`migration_generator.ex:38`) and **silently skips** multi-datalayer resources;
the library ships `AshMultiDatalayer.Migration` (runtime shadow modules) plus
`mix ash_multi_datalayer.generate_migrations` and a `codegen/1` hook for
`mix ash.codegen`. An upstream `ash_postgres` PR to make discovery pluggable is
planned.

- [ ] `mix ash_multi_datalayer.generate_migrations` on a multi-datalayer
      resource produces migrations **byte-identical** to those of a twin
      resource using `AshPostgres.DataLayer` directly.
- [ ] Relationship FKs survive: shadow modules rewrite relationship source
      **and** destination to shadows.

### Coverage + backfill

**File**: `test/integration/subsumption_test.exs`

- [ ] **Subsumption hit**: `name == "foo"` then
      `name == "foo" and age     > 18`; second call does not touch Postgres (via
      layer-call counter).
- [ ] **Subsumption miss**: `name == "foo"` then `name == "bar"`; second call
      hits Postgres.
- [ ] **Backfill**: after a cache miss, rows are upserted into `:l1` and the
      filter is recorded in the ledger.
- [ ] **Cold read from empty cache**: primary has rows, cache is empty; read
      returns rows and populates cache.

### Row-aware invalidation

**File**: `test/integration/row_aware_invalidation_test.exs`

- [ ] Load `name == "foo"` (2 matching rows); update one row's `name` to
      `"bar"`; next read of `name == "foo"` hits Postgres; next read of
      `age > 18` (unrelated) hits cache.
- [ ] Destroy a matching row — entry dropped.
- [ ] Create a new matching row — entry dropped.
- [ ] Create/update that doesn't match any ledger entry — no entries dropped.

### Kill-switch

**File**: `test/integration/kill_switch_test.exs`

- [ ] Default: cache hits.
- [ ] After `AshMultiDatalayer.disable!/1`: all reads route to `:l2`.
- [ ] After `enable!/1`: cache hits again.

### Ledger cap

**File**: `test/integration/ledger_cap_test.exs`

- [ ] Configure `ledger_max_entries 5`; insert 6 distinct filter shapes; assert
      5 remain and the 6th replaced the oldest.
- [ ] `:evicted` telemetry fires once per eviction.

### Divergence sampler

**File**: `test/integration/divergence_sampler_test.exs`

- [ ] Configure sampler 1.0 (always sample); seed cache with stale row; read;
      assert `:divergence_detected` telemetry with correct PK delta.
- [ ] Sampler 0.0: never fires.

### Capability matrix

**File**: `test/ash_multi_datalayer/capabilities_test.exs`

- [ ] For each `(read_order, write_order)` combination from the plan's
      capability table, assert `can?/2` returns the expected value for
      `:transact`, `:filter`, `:sort`, `{:aggregate, :count}`.

### Tenant isolation

**File**: `test/integration/tenant_isolation_test.exs`

- [ ] Tenant A loads `name == "foo"` (caches in tenant A's ledger).
- [ ] Tenant B loads `name == "foo"` — cache miss (no cross-tenant coverage);
      separate ledger entry created.
- [ ] Write in tenant A — B's ledger entries untouched.

## Property-Based Tests

### Solver implication

**File**: `test/ash_multi_datalayer/coverage/implication_property_test.exs`

Generator: `{cached_filter, probe_filter, row}` tuples over a finite
attribute+value domain.

```
property "implies? is sound" do
  check all {cached, probe, row} <- triple_generator(), max_runs: 10_000 do
    if implies?(cached, probe) do
      # cached implies probe: if cached matches row, probe must also
      assert not matches?(cached, row) or matches?(probe, row)
    end
  end
end
```

**Target**: 10 000 runs, zero counterexamples.

### Row-aware invalidation

**File**: `test/ash_multi_datalayer/coverage/invalidation_property_test.exs`

```
property "should_drop? is sound" do
  check all {filter, row_before, row_after} <- generator() do
    should_drop = Invalidation.should_drop?(filter, row_before, row_after)
    ground_truth =
      matches_or_unknown?(filter, row_before) or
      matches_or_unknown?(filter, row_after)
    assert should_drop == ground_truth
  end
end
```

## Edge Cases and Error Scenarios

### Tenant `nil` on a non-multitenant resource

- **Input**: resource without `multitenancy`, read with no tenant.
- **Expected behavior**: `:__global__` sentinel; reads work normally; no
  cross-tenant risk because there's only one tenant.
- **Test**: `test/integration/nil_tenant_test.exs`.
- **Risk**: the sentinel must be distinct from any value that could appear as a
  real tenant atom.

### Layer failure mid-write

- **Input**: `:l2` succeeds, `:l1` raises.
- **Expected behavior**: operation succeeds (primary committed);
  `:failed_at_layer` telemetry fires; subsequent reads fall through and
  backfill.
- **Test**: `test/integration/layer_failure_test.exs`.

### Kill-switch flip during concurrent reads

- **Input**: reads in flight when `disable!/1` is called.
- **Expected behavior**: no crash; in-flight reads may use either path;
  subsequent reads use the disabled path.
- **Test**: `test/concurrent/kill_switch_concurrent_test.exs` with many
  processes.

### Ledger insertion race

- **Input**: two concurrent misses for the same filter.
- **Expected behavior**: at most two ledger entries (we don't coordinate);
  subsequent reads recognise coverage regardless.
- **Test**: `test/concurrent/ledger_insertion_race_test.exs`.

## What We're NOT Testing (and why)

- **Multi-node clustering**: out of scope for v1 per single-node ADR.
- **Oban write-behind paths**: removed in v1.
- **N>2 layer configurations**: generalises in code but not exercised in CI; v1
  only tests 2-layer.
- **Performance of `Ash.DataLayer.Ets` itself**: upstream library, not ours.
- **Property tests for telemetry fingerprint hash collisions**: fingerprints are
  convenience metadata, not correctness-critical.

## Quality Gates

| Gate        | Criteria                              | Threshold                       |
| ----------- | ------------------------------------- | ------------------------------- |
| Pre-commit  | `mix format --check-formatted`        | Zero diffs                      |
| Pre-commit  | `mix credo --strict`                  | No errors or new warnings       |
| Pre-merge   | `mix test`                            | 100 % pass                      |
| Pre-merge   | `mix test --only property`            | Zero counterexamples            |
| Pre-merge   | `mix dialyzer`                        | No new warnings                 |
| Pre-release | Benchmarks (`bench/`)                 | p99 solver ≤ 500 µs; inv ≤ 2 ms |
| Pre-release | Manual smoke in author's host project | Pass                            |

## Exploratory Testing

### Charter: DSL ergonomics

> **Explore** the `multi_data_layer` DSL **with** misconfigurations, missing
> layers, inverted orders, and novel combinations **to discover** verifier gaps,
> confusing error messages, and footguns.

**Timebox**: 90 minutes, pre-0.1.0 release.

### Charter: Solver hit rate on real filter shapes

> **Explore** cache hit rate **with** the author's own production Ash resource's
> action filters **to discover** which supported predicates give high hit rate
> and which shape of query short-circuits the solver.

**Timebox**: 60 minutes, pre-release.

## Manual Verification Checklist

- [ ] `iex -S mix`, compile a test resource, exercise
      `Ash.create!`/`Ash.read!`/`Ash.get!`, observe both ETS and Postgres rows.
- [ ] `AshMultiDatalayer.Debug.dump_ledger/1` returns sensible output.
- [ ] `AshMultiDatalayer.Debug.explain_covers?/2` prints a trace.
- [ ] `mix ash_multi_datalayer.disable RESOURCE` works and
      `mix ash_multi_datalayer.inspect RESOURCE` reflects the state.
- [ ] Telemetry events visible via a `:telemetry.attach_many/4` snippet.

## Test Data and Fixtures

| Fixture                  | Purpose                          | Created By                      | Cleanup                             |
| ------------------------ | -------------------------------- | ------------------------------- | ----------------------------------- |
| `TestRepo`               | Postgres backing primary layer   | `test/support/test_repo.ex`     | Ecto sandbox; truncate on each test |
| `TestResource`           | Canonical two-layer resource     | `test/support/test_resource.ex` | N/A (module)                        |
| `TestResource.Migration` | Schema creation                  | `test/support/migration.ex`     | `mix ecto.drop` between suites      |
| `StreamData` generators  | Random filter, row, value combos | `test/support/generators.ex`    | N/A                                 |

## Running Tests

```bash
# All tests
mix test

# Fast unit-only run (skip property + integration):
mix test --exclude property --exclude integration

# Property suite only (slow):
mix test --only property

# Integration only:
mix test --only integration

# With coverage (diff coverage preferred for PRs):
mix coveralls.html
```

---

**Last Updated**: 2026-07-03
