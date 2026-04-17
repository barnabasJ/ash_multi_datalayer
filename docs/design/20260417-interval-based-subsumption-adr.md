# 20260417-Interval-Based-Subsumption-ADR

**Status**: Accepted **Date**: 2026-04-17 **Deciders**: Barnabas Jovanovics

## Decision Drivers

- Correctness is non-negotiable: a wrong `implies?/2` returns stale rows, the
  worst possible cache failure mode.
- We need _provable_ subsumption on the supported predicate set, not "probably
  correct based on a property test."
- Implementation budget is limited; v1 cannot support a full SMT toolchain.
- The supported predicate set (equality, inequality, ranges, IN, is_nil,
  conjunctions, disjunctions) is structurally amenable to a simpler decidable
  representation.

## Context

The original plan proposed a SAT-style reduction over
`Ash.Query.BooleanExpression`: build `cached AND NOT incoming` and check for
unsatisfiability. General SAT/SMT is overkill for the supported predicate
subset, which is small enough to admit a direct decision procedure. The
architect review recommended switching to a per-attribute interval
representation for exactly this reason.

## Decision

**We will canonicalise filters to a disjunction of per-attribute interval
constraints and decide subsumption by set containment: `implies?(A, B)` iff
every disjunct of A is contained in some disjunct of B on every attribute.**

### Implementation Details

For each disjunct, per attribute, we produce an `%Interval{}` with:

- `op` — one of `:eq | :range | :in | :is_nil | :not`
- `lower`, `upper` — inclusive/exclusive bounds for ranges
- `values` — concrete values for `:eq` / `:in`

Subsumption check:

```elixir
def implies?(%Normalised{disjuncts: a_dnf}, %Normalised{disjuncts: b_dnf}) do
  Enum.all?(a_dnf, fn a_disjunct ->
    Enum.any?(b_dnf, fn b_disjunct ->
      attrs_subset?(a_disjunct, b_disjunct)
    end)
  end)
end
```

Complexity: O(disjuncts × attributes × predicates per attribute) per call.
Linear in filter size.

Unsupported predicate shapes (fragments, custom functions, relationship filters,
array operators, case-insensitive comparisons) normalise to `:opaque` and never
participate in subsumption — conservative-on-unknown is the correctness
invariant.

## Consequences

### Positive

1. Correctness is **decidable by construction**; the property test becomes a
   regression test, not the primary correctness argument.
2. No external solver dependency.
3. O(n) per call rather than worst-case exponential for SAT.
4. Straightforward to extend with additional predicate shapes later — each
   becomes a new `Interval` case.

### Negative

1. Some filter shapes a full SAT solver would handle correctly are rejected by
   interval-containment (e.g., `x + y > 0 implies x > -y`). These fall through
   to the primary — correct, but lose hit rate.
2. Normalising to DNF can explode conjunctions of disjunctions
   (`(a OR b) AND (c OR d)` → 4 disjuncts). Mitigate with a configurable
   disjunct limit; above the limit, normalise to `:opaque` and fall through.

### Mitigations

- Document the supported shape cleanly in the user guide.
- Tests include the "SAT would say yes, we say no" cases so users can see the
  boundaries.

## Alternatives Considered

### Alternative 1: SAT-style reduction over `Ash.Query.BooleanExpression`

- Good, because maximally general; any filter we can express we can reason
  about.
- Good, because reuses an existing Ash data structure.
- Bad, because correctness rests on the solver; a solver bug is a stale-read
  bug.
- Bad, because worst-case complexity is exponential; we'd need a timeout +
  fallback.
- Bad, because any solver we'd write from scratch has unknown correctness; any
  off-the-shelf solver is a heavy dependency.

**Why not**: Correctness cost too high for the added expressiveness.

### Alternative 2: Structural equality only (no subsumption)

- Good, because trivially correct.
- Bad, because equivalent filters with different syntactic shape miss.
- Bad, because no cross-filter inference.

**Why not**: Would make the feature called "filter subsumption" a misnomer.

### Alternative 3: Pure PK-presence cache

- Good, because simplest possible.
- Good, because no solver.
- Bad, because filtered list reads never hit the cache — the main use case the
  user asked for.

**Why not**: User explicitly chose subsumption over PK-only when presented with
the options.

## Validation

- Property suite: 10 k randomly-generated `{cached, probe, row}` triples;
  `implies?(cached, probe)` cross-checked against brute-force evaluation on a
  finite domain. Zero counterexamples.
- A user-reported cache miss turns out to be SAT-would-say-covered → consider
  extending intervals or reconsider the solver decision.

## Links

- [RFC](./ash-multi-datalayer-rfc.md) — architect recommendation.
- Plan section: "Implication solver."

---

**Last Updated**: 2026-04-17
