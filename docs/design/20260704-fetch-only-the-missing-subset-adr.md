# 20260704-Fetch-Only-The-Missing-Subset-ADR

**Status**: Accepted **Date**: 2026-07-04 **Deciders**: Barnabas Jovanovics

## Decision Drivers

- The coverage ledger already proves what the cache holds, but reads only
  exploited it in the all-or-nothing cases: a fully-covered read hit the cache,
  everything else fell through **whole** to the source. Partially-covered reads,
  and reads loading a reproducible calculation, paid a full source round trip
  they didn't need.
- ash_remote's Feature A makes proxied calcs filterable/sortable by emitting
  them as `remote(...)` custom expressions that advertise `:unknown` on
  non-remote layers. Without matching routing, ash_multi_datalayer would treat a
  `remote()` calc filter as a plain attribute — risking a false coverage hit and
  evaluating a source-only calc on the cache layer (wrong rows).
- We want one coherent model, not three bolt-ons, and it must stay data-layer
  agnostic.

## Decision

**ash_multi_datalayer is a router, never a calculator.** It never evaluates a
calculation or filter itself; it routes each piece of work to the read layer
that can handle it, using that layer's own capability advertisement. One
principle unifies the read path — **serve what is soundly cached, fetch only the
genuine delta from a lower layer** — with three faces:

- **Missing values** → _merge reads_ (the prior ADR) + _local evaluation_: the
  cache holds the rows; a calc's value is computed on whichever layer can, and
  only the values a layer _can't_ compute are fetched from the source.
- **Missing rows** → _remainder reads_: the cache holds part of `Q`; the source
  supplies only the rest.

### Local evaluation (was "Alternatives Considered" in the merge-reads ADR)

The merge-reads ADR deferred local evaluation. It is now implemented as a
**routing** decision, not a re-computation: `query.calculations` is partitioned
into `{cache-evaluable, source-only}` and the cache-evaluable calcs are kept on
the cache-delegated read so the cache layer computes them; only the source-only
ones round-trip. A mirrored expression (`overdue?`) is computed by the cache
from the covered rows — **0 source reads**; a `remote()` calc is source-only.

The signal is the capability probe (`AshMultiDatalayer.Capability`): a calc is
cache-evaluable iff every `Ash.CustomExpression` in its expression has a
resolvable `simple_expression` (the in-VM form Ash's runtime evaluates). Ash
does **not** retain the custom expression's `:module` through hydration, so
`simple_expression` — not the module — is the signal. Default-on, with a
per-calc `local_evaluation_overrides` escape hatch and a resource-level
`local_evaluation?` switch.

### Remainder reads (was "Future work" in the merge-reads ADR)

Two correctness obligations, both on the correctness path:

1. **Prove `C`** — a sound _under-approximation_ of what the cache holds (the
   union of current ledger entries). Over-claiming `C` would make the remainder
   under-fetch and silently drop rows; under-claiming just over-fetches
   (PK-dedup cleans it up). Unrepresentable coverage is simply not claimed →
   conservative full read, never a wrong result. This is grammar-bounded by the
   normaliser.
2. **Fetch `¬C`** — a **total, nil-safe complement** of `C`
   (`AshMultiDatalayer.Coverage.Complement`). Every leaf is complemented in
   positive form with an explicit `is_nil` escape hatch (`¬(a > 5)` →
   `a <= 5 or is_nil(a)`), so **no three-valued `NOT` ever reaches SQL / the
   wire / the runtime** — the exact hazard that drops nil-attribute rows. De
   Morgan composes exact complements exactly, so `C ∨ ¬C` is the universe and
   `(Q ∧ C) ∪ (Q ∧ ¬C) = Q` for any `Q`.

A partially-covered plain read then serves `Q ∧ C` from the cache and fetches
only `Q ∧ ¬C` from the source, PK-merges (preferring fetched rows), backfills
the full result, and records `Q` (the next read is a full hit). Eligibility:
recordable (no limit/offset/distinct/lock), unsorted, single-PK. The
completeness property suite (`match(Q) ⇒ match(Q∧C) ∨ match(remainder)` over
nil-heavy rows vs `Ash.Filter.Runtime`) is the gate. The complement is built
**general from the start** — no OR-decomposition-first staging — because the
nil-safe construction makes generality and soundness arrive together.

### Calc-referencing filters/sorts route to a capable layer

A `Ref` whose attribute is a `Calculation`/`Aggregate` is **opaque** to the
normaliser (it was structurally matched as a plain attribute via `:name`/`:type`
— a latent false-hit hazard). Opaque routes a calc filter to the source. A sort
referencing a calc the cache can't evaluate likewise routes the whole query to
the source. The source (ash_remote) forwards the predicate to the server, which
resolves it with real semantics.

## The layer-consistency contract (explicit)

**ash_multi_datalayer assumes its read layers return the same value for any
expression they all claim to support.** Ensuring that — matching collation,
numeric/date semantics, a correct three-valued implementation — is the
**operator's** responsibility, not a rule ash_multi_datalayer enforces. It adds
no per-function "portable grammar", no eligibility list, no exclusions — that
would be exactly the data-layer-specific coupling we avoid. The divergence
sampler stays as _observability_ (surfaces a mismatch as telemetry), never a
gate. `today()`/`now()` need no special case: calcs are computed fresh at read
time, so they are evaluated at the same instant a source read would be.

The **complement** is the one thing that stays ash_multi_datalayer's own
responsibility — but it is pure structural logic that evaluates nothing and
knows no backend, so it does not violate agnosticism. Its totality is our gate;
value agreement across layers is the operator's.

## Consequences

### Positive

- Partially-covered reads and reproducible-calc reads stop paying full source
  round trips. `overdue?` on a warm cache is 0 source reads; a partial read
  fetches only the uncovered rows.
- One capability signal drives filter routing, sort routing, and value
  computation — no bespoke rules per feature.
- The nil-safe complement designs out the `Ash.Filter.Runtime`-vs-backend
  three-valued divergence that earlier spikes hit, rather than testing around
  it.

### Negative

- Remainder reads issue an extra (in-VM, non-source) cache query per partial
  read; the source query is same-or-smaller than the old whole fall-through.
- The layer-consistency contract pushes a real responsibility onto the operator
  (collation, etc.). Divergence is observable but not prevented.
- Remainder eligibility excludes sort/limit/offset/distinct/lock and composite
  PKs — those fall through whole (correct, not minimal).

## Alternatives Considered

- **A per-function "portable grammar" in ash_multi_datalayer** to decide which
  calcs are safe to evaluate locally. Rejected: data-layer-specific coupling;
  the layer-consistency contract replaces a whole category of such rules.
- **OR-decomposition-first remainder** (covered disjuncts from cache, uncovered
  fetched verbatim, negation deferred). Rejected as the _only_ v1 step: the
  nil-safe positive-form complement is general and sound from the start, so
  there is no need to ship the restricted version first.

## Validation

- `AshMultiDatalayer.Coverage.ComplementPropertyTest` — the completeness gate.
- Integration: local eval (0 source reads), remainder reads (nil-row survival,
  filter composition, remainder == cache-disabled read), calc filter/sort
  routing. End-to-end in `example/todo_client` over `AshRemote.DataLayer`.

## Links

- [Computed-Value Merge Reads ADR](20260703-computed-value-merge-reads-adr.md) —
  the missing-values face; this ADR implements its deferred local-evaluation
  alternative and its remainder-reads future work.
- [Interval-Based Subsumption ADR](20260417-interval-based-subsumption-adr.md) —
  the normaliser grammar the complement is built on.
- [Partial-Serving / Remainder-Reads plan](../plans/partial-serving-remainder-reads-plan.md)
  — the detailed implementation sketch (its OR-decomposition-first risk ordering
  is superseded here by the general nil-safe complement).
