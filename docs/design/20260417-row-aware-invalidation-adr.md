# 20260417-Row-Aware-Invalidation-ADR

**Status**: Accepted **Date**: 2026-04-17 **Deciders**: Barnabas Jovanovics

## Decision Drivers

- The library must retain its value under realistic write load. "Subsumption"
  that doesn't survive writes is a theoretical feature.
- Correctness on invalidation is as important as correctness on subsumption —
  dropping too few entries returns stale rows.
- Reuse of existing Ash primitives (`Ash.Filter.Runtime.do_match/2`) is strongly
  preferred over a bespoke implementation.

## Context

The original plan used "drop all ledger entries for resource+tenant on any
write" as a v1 simplification, with row-aware invalidation flagged as a "fast
follow-up." The architect review pointed out — and a simple trace confirmed —
that under any sustained write load, this clears the ledger faster than reads
can warm it. The resulting system is **strictly worse** than a plain PK cache:
every read still hits the primary, but now also pays the cost of maintaining
cache state. Row-aware invalidation is what makes the subsumption investment pay
off.

## Decision

**We will ship row-aware ledger invalidation in v1: on every write, drop only
ledger entries whose filter matches `row_before` or `row_after` by concrete
evaluation, keeping unrelated entries.**

### Implementation Details

```elixir
def on_write(resource, tenant, operation, row_before, row_after) do
  ledger = Coverage.entries(resource, tenant)

  Enum.each(ledger, fn %Entry{filter: f, id: id} ->
    matches_before = row_before && filter_runtime_match?(f, row_before)
    matches_after  = row_after  && filter_runtime_match?(f, row_after)

    cond do
      matches_before == :unknown or matches_after == :unknown ->
        # Conservative: drop on unsupported predicates
        Coverage.drop(resource, tenant, id)
      matches_before == true or matches_after == true ->
        Coverage.drop(resource, tenant, id)
      true ->
        :keep
    end
  end)
end
```

`filter_runtime_match?/2` wraps `Ash.Filter.Runtime.do_match/2` and translates
fall-through cases (unsupported predicate, missing field) to `:unknown` rather
than `false` — so unknown evaluation drops the entry rather than optimistically
keeping it.

Cost: O(ledger_size × filter_complexity) per write. With `ledger_max_entries`
default 10 000 and typical filter complexity, this runs in ≤ 2 ms per write on a
developer laptop (gated by a benchmark before release).

For `create`: `row_before` is `nil`; only `row_after` is evaluated. For
`destroy`: `row_after` is `nil`; only `row_before` is evaluated. For `update` /
`upsert`: both.

## Consequences

### Positive

1. The ledger retains entries for filters that don't touch the changed row, so
   the subsumption investment pays off under write load.
2. Operator review's flagship concern on this axis is addressed in v1.
3. Reuses existing `Ash.Filter.Runtime` primitive; no new evaluation logic.

### Negative

1. Every write pays an O(ledger_size) cost. With a 10 000-entry cap and ≤ 2 ms
   p99, this is fine; a larger cap or deeply nested filters could push this into
   milliseconds-per-write territory.
2. Unsupported predicates drop entries conservatively — some keep-able entries
   are dropped on writes that touch complex filters. Acceptable: same
   "conservative on unknown" principle as subsumption.

### Mitigations

- `ledger_max_entries` default is chosen with this cost in mind and gated by a
  benchmark.
- Invalidation work is done synchronously in the write path so it can't race
  with subsequent reads on the same tenant; if this becomes a bottleneck, move
  to a per-tenant ETS table + parallel scans.
- Telemetry `[:ash_multi_datalayer, :ledger, :invalidated]` reports count
  dropped; operators can see when invalidation is expensive.

## Alternatives Considered

### Alternative 1: Drop-all on any write (original plan)

- Good, because trivially correct.
- Good, because O(1) invalidation.
- Bad, because clears the ledger faster than it warms under any write load,
  defeating the point of subsumption.

**Why not**: Makes `:cache_first` strictly worse than a plain PK cache under
realistic write load. Architect review blocker.

### Alternative 2: TTL-based entries (no proactive invalidation)

- Good, because simple.
- Good, because bounded memory.
- Bad, because reads return stale rows for up to TTL seconds after a write. Not
  a cache, a consistency-weakened read.

**Why not**: Violates the "no stale reads" correctness invariant.

### Alternative 3: Versioned row tags in the cache

- Good, because invalidation can be O(1) lookups.
- Good, because row-specific.
- Bad, because requires a version column on every cached resource or a
  side-channel version store.
- Bad, because ledger entries need to remember row versions, not just filters.

**Why not**: Substantially more complex than row-aware invalidation via existing
`Ash.Filter.Runtime`.

## Validation

- Benchmark: 100 reads/sec + 20 writes/sec across 20 filters, ledger retention ≥
  80 % on a realistic workload.
- Property test: generated `{filter, row_before, row_after}` triples;
  `should_drop?/3` cross-checked against the same `Ash.Filter.Runtime`
  evaluator. Zero counterexamples.
- A user reports "invalidation is the bottleneck" → revisit alternatives.

## Links

- [RFC](./ash-multi-datalayer-rfc.md) — architect + operator reviews.
- Plan section: "Row-aware invalidation."

---

**Last Updated**: 2026-04-17
