# 20260417-Generic-Ordered-Layers-ADR

**Status**: Accepted **Date**: 2026-04-17 **Deciders**: Barnabas Jovanovics

## Decision Drivers

- The library will be used for caching _and_ other layered-storage patterns
  (cold-tier storage, migration mirroring, polyglot persistence, audit fan-out).
- Baking caching semantics into the DSL (`:cache` / `:primary` names,
  `:cache_first` / `:write_through` strategy enums) would force a rename/rewrite
  the first time a non-caching user shows up.
- Ash DSLs tend to favour explicit lists over named enums when the underlying
  model is compositional.

## Context

The original plan used named layer slots (`:cache`, `:primary`) and enumerated
strategy atoms (`:cache_first`, `:write_through`, `:primary_only`,
`:write_behind`). The skeptic review argued that a library claiming to be a
"multi datalayer" was silently a "cache datalayer" in disguise; the user agreed
and asked for generic naming so future layered-storage use cases fit without an
API break.

## Decision

**We will use generic ordered-slot layer names (`layer :l1, module`,
`layer :l2, module`, …) and replace strategy enums with explicit lists
(`read_order [:l1, :l2]`, `write_order [:l2, :l1]`, `backfill? true`).**

### Implementation Details

```elixir
multi_data_layer do
  layer :l1, Ash.DataLayer.Ets
  layer :l2, AshPostgres.DataLayer

  read_order  [:l1, :l2]
  write_order [:l2, :l1]
  backfill?   true
end
```

Caching intent is expressed by the combination; other intents use different list
shapes. Named strategy enums are removed.

## Consequences

### Positive

1. One library covers caching + tiering + migration mirroring + polyglot
   persistence without DSL changes or a rewrite.
2. The capability-negotiation story simplifies: `can?/2` is the intersection of
   layers named in the relevant `*_order`. No special- casing for
   `:primary_only`.
3. Documentation can present recipes (caching, cold-tier, mirror) as different
   list shapes rather than mutually-exclusive feature flags.

### Negative

1. DSL is marginally more verbose — two lists instead of two enums.
2. Common cases have no shorthand; every resource spells out `read_order` and
   `write_order`. Can be mitigated with sensible defaults (default `read_order`
   = layer declaration order; default `write_order` = reverse) in a future
   iteration if it proves noisy.
3. Layer names carry no semantics; a misconfigured `write_order [:l1]` writing
   only to a cache layer is a correctness bug the user has to reason about. A
   verifier rejects obviously-wrong shapes, but can't catch all user intent.

### Mitigations

- Documented recipes in the user guide for the four most common layering
  patterns.
- Verifier messages that name the resource + the shape of the misconfiguration
  explicitly.

## Alternatives Considered

### Alternative 1: Keep `:cache` / `:primary` named layers + strategy enums

- Good, because reads naturally (`read_strategy :cache_first`).
- Good, because strategy enums are compact.
- Bad, because the library is then a caching library with an aspirational name.
- Bad, because the first non-caching user needs an API break.

**Why not**: The user explicitly asked for generic naming so other
layered-storage patterns fit.

### Alternative 2: Positional layers without names (`layer Module1`, `layer Module2`)

- Good, because terse.
- Bad, because `read_order` / `write_order` have nothing to refer to — positions
  would have to be referenced by index, which is fragile on reorder.
- Bad, because error messages become "the second layer failed" with no
  user-chosen identifier.

**Why not**: Named layers are strictly better for diagnostics.

## Validation

- An adopter can express at least two non-caching recipes (cold-tier, migration
  mirror) without extending the DSL → validates.
- A user complains the DSL is too verbose and asks for a `cache:` macro →
  reconsider with a shorthand that expands to the lists.

## Links

- [RFC](./ash-multi-datalayer-rfc.md) — multi-perspective review.
- [PRD](./ash-multi-datalayer-prd.md).
- Plan: `../plans/ash-multi-datalayer-plan.md`.

---

**Last Updated**: 2026-04-17
