# 20260703-Computed-Value-Merge-Reads-ADR

**Status**: Accepted **Date**: 2026-07-03 **Deciders**: Barnabas Jovanovics

## Decision Drivers

- Queries that load calculations or aggregates currently bypass coverage
  entirely (miss reason `:not_cacheable`) and fall through whole — even when
  the *rows* are perfectly covered by the ledger. Pages that lean on computed
  values (counts, server-side calculations) get zero benefit from the cache.
- Computed values must stay server-computed: reproducing them from cached
  rows is either impossible (the client lacks the formula — e.g. ash_remote's
  generated calculation stubs are placeholders) or unsound (an aggregate over
  a cached subset silently undercounts). The v1 non-goal "not re-computed
  over a cache subset" stands.
- With a remote source of truth the fall-through cost is a full HTTP response
  carrying every row; the computed values themselves are a fraction of that
  payload.

## Context

The flagship composition (ETS over `AshRemote.DataLayer`) makes the cost
visible: the example's overview page loads `todo_count`, `completed_count`,
and `overdue?`, so every render re-fetches all rows from the server although
the ledger already proves the cache holds them. The insight: a computed value
is a **per-row, primary-key-addressable fact**. If the rows are covered, the
only thing the wire needs to carry is `{pk, computed values}`.

## Decision

**Split reads that load calculations/aggregates: serve the rows from the
cache when the ledger covers the filter, then issue ONE narrow value query
against the source of truth — `primary_key in [cached row pks]`, selecting
only the primary key plus the requested calculations/aggregates — and merge
the returned values into the cached records by primary key.**

### Scope amendment (found during implementation)

Merge reads ship for **calculations only**. Resource (relationship)
aggregates cannot be pushed to SQL layers from a multi-datalayer resource at
all: ash_sql builds the related subquery by calling
`Ash.Query.data_layer_query/1` on the **destination resource**, whose data
layer is this library — yielding our query struct instead of SQL, so the
aggregate comes back silently `NotLoaded` (this affected plain fall-through
reads too, not just merges, and had gone undetected). Rather than silence,
`can?({:aggregate, _})` is now `false`: Ash raises `AggregatesNotSupported`
at query build. Self-aggregation (`Ash.count/2` → `run_aggregate_query`)
still works, and remote-style aggregates (ash_remote's arrive as
calculations) are unaffected. The merge machinery itself is
aggregate-shaped-value ready and can be re-enabled per-kind once an upstream
seam exists (ash_sql resolving related subqueries through something
pluggable instead of the destination's persisted data layer).

### Implementation Details

`run_query/2` decision tree changes for queries with non-empty
`calculations` (locks continue to bypass):

1. Resource must be **mergeable**: single-attribute primary key (a composite
   PK has no clean `in` filter). Otherwise: full fall-through,
   `:not_cacheable`, as today.
2. Coverage is checked for the **row part** of the query (the query with
   computed loads stripped; `covers?` semantics unchanged — filter implied,
   fields ⊆ `loaded_fields`).
3. **Hit** → the row query runs on the cache layer (it applies its own
   sort/limit/offset, so the value query only covers rows actually
   returned), then the value query runs on the last read layer and values
   are merged by PK. Emits `[:read, :hit]`. The divergence sampler still
   applies (the shadow read uses the full original query).
4. **Miss** → the full original query falls through to the source of truth,
   exactly as today — but the fetched rows are now backfilled and the row
   coverage **recorded** (previously calc/agg-carrying queries were never
   recorded; the rows are complete for the filter, so recording is sound —
   `recordable?` drops its calculations/aggregates exclusions, keeping
   limit/offset/distinct/lock).

Values merge to wherever the source layer placed them: the loaded field when
`load:` is set, else the record's `calculations`/`aggregates` map.

### Conservative fallbacks (never partial results)

- **Cached row without a source counterpart** (the row was deleted
  out-of-band): the merge is abandoned and the query falls through whole —
  fresh rows and values, never a row missing its computed value.
- **Value query failure**: fails the read (fail-fast, like any read-path
  layer error). No "rows without their calcs".
- **Composite primary keys**: full fall-through (v1.1 scope cut).

### What this deliberately does NOT do

- No local evaluation of calculations, even trivially evaluable ones —
  values always come from the source of truth. Local evaluation of
  data-mirrorable expressions is a separate future step and depends on
  ash_remote shipping real expressions in its manifest (see the ash_remote
  follow-up notes).
- No caching of computed values: they are fetched fresh on every read that
  loads them. The freshness guarantee for computed values is unchanged.
- No cross-resource coverage reasoning: aggregates are *fetched*, not proven
  coverable.

## Consequences

### Positive

1. Computed-value pages get row-level caching: the wire carries only
   `{pk, values}` instead of full rows. For remote sources of truth this is
   the difference between "cache useless on this page" and "cache pays for
   most of the payload".
2. Computed values remain the server's truth on every read — the v1
   correctness stance is untouched.
3. Row coverage recorded from calc-carrying misses warms the cache for
   *plain* reads too (previously these misses left no trace).

### Negative

1. A merged read still makes one round-trip — this is a payload
   optimisation, not a round-trip eliminator. Pages wanting zero RPCs must
   still avoid computed loads (derive in the view).
2. The PK-`in` value query grows with result size; for very large covered
   result sets the original filter might have been cheaper for the server.
   Mitigation: the value query reuses the rows the cache layer already
   limited, and huge unlimited reads are equally heavy on the fall-through
   path today.
3. Slightly wider `run_query/2` decision tree (one more branch and module).

## Alternatives Considered

### Local evaluation over cached rows

Compute calculations client-side (Ets can evaluate expressions) and
aggregates by counting cached rows. **Rejected for now**: the client often
lacks the real formula (ash_remote stubs), aggregates require cross-resource
coverage proofs to avoid silent undercounting, and both break the "computed
values are the server's truth" line. Revisit as an opt-in once ash_remote
mirrors expressions.

### Batched remote module calculations (ash_remote-side)

Generate module-based calculations whose `calculate/3` makes one batched RPC.
Complementary, not competing: it covers standalone `Ash.load(records, :calc)`
on pure ash_remote resources, and its metadata-prefetch variant lets a data
layer that already fetched values hand them over without a second request.
Noted in ash_remote's plan; the merge read keeps ash_multi_datalayer
layer-agnostic (it works identically over AshPostgres).

### Cache the computed values with row-aware invalidation

Store fetched values in the cache and invalidate on writes. **Rejected**:
values depend on data the ledger cannot see (aggregates over other
resources' rows, server-clock expressions), so invalidation cannot be made
row-aware — it would be TTL-or-wrong, which v1 explicitly avoids.

## Validation

- Integration: warmed plain coverage + calc-loaded read → rows served with
  zero source row-refetch, one value query, values equal the source's.
- Merged aggregate/calc values equal a cache-disabled read's values
  (equivalence sweep).
- Stale-cache fallback: delete a row out-of-band, merged read falls through
  whole and returns fresh data.
- The ash_remote example's overview-page reads become row-cache hits with
  value queries (the calc/aggregate freshness canary in the example's T0/T5
  must stay green — values fresh on every read).

## Links

- [Interval-subsumption ADR](./20260417-interval-based-subsumption-adr.md) —
  the coverage machinery the row part reuses.
- PRD non-goal "Aggregates / calculations … not re-computed over a cache
  subset" — unchanged in spirit; this ADR narrows *what falls through* from
  "the whole query" to "the computed values".
- ash_remote follow-ups (mirroring expressions, unevaluable stubs, batched
  remote calculations): `ash_remote_implementation_plan.md` in the ash_remote
  repo.

---

**Last Updated**: 2026-07-03
