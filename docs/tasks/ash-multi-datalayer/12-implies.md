# Task 12: `Coverage.Implication.implies?/2`

**Phase**: 5 — Implication solver **Depends on**: 11 **Blocks**: 13, 14, 15, 27
**Size**: L

## Objective

Implement `AshMultiDatalayer.Coverage.Implication.implies?/2` — given two
normalised filters (DNF of per-attribute intervals from Task 11), return `true`
iff the first filter logically implies the second.

## Out of Scope

- The normaliser itself (Task 11).
- The property-based test suite (Task 13) — unit tests only here.
- Integration with the read path (Task 15).
- Support for `fragment`, custom functions, relationship filters, or array
  operators — those normalise to `:opaque` in Task 11 and are handled by this
  function returning `false` on them.

## Context

The solver is the correctness core of the library. A wrong `implies?/2` returns
stale rows — the worst possible failure mode. Per
[ADR 20260417-interval-based-subsumption](../../design/20260417-interval-based-subsumption-adr.md),
correctness is decidable by set containment on per-attribute intervals.

## Detailed Steps

### 1. Shape of `implies?/2`

```elixir
defmodule AshMultiDatalayer.Coverage.Implication do
  @moduledoc """
  Filter-subsumption solver for the coverage ledger.
  """

  alias AshMultiDatalayer.Coverage.Normalised

  @doc """
  Returns `true` iff `cached` logically implies `probe`.

  Both arguments must already be normalised to per-attribute interval
  DNF by `Normalise.normalise/1`.

  Conservative on uncertainty: when the answer cannot be determined
  (e.g., opaque predicates, mixed attribute types), returns `false`.
  """
  @spec implies?(Normalised.t(), Normalised.t()) :: boolean()
  def implies?(%Normalised{disjuncts: cached}, %Normalised{disjuncts: probe}) do
    Enum.all?(cached, fn cached_disjunct ->
      Enum.any?(probe, fn probe_disjunct ->
        attrs_subset?(cached_disjunct, probe_disjunct)
      end)
    end)
  end
end
```

### 2. Attribute-set containment

> **Warning — the original pseudocode here was unsound** (caught during
> implementation by the property suite): it iterated only the cached (LHS)
> side's attributes, so an attribute constrained only on the probe (RHS) side
> was silently ignored — `{name: foo}` would wrongly imply
> `{name: foo, age > 18}`. The containment check must iterate the **union** of
> both sides' attribute keys, and an attribute missing from the cached side
> (i.e. unconstrained on the LHS) must yield `false`.

```elixir
defp attrs_subset?(cached_disjunct, probe_disjunct) do
  # A cached disjunct is a subset of a probe disjunct iff, for every
  # attribute constrained on EITHER side:
  #   - constrained on both: cached's interval is contained in probe's;
  #   - constrained only on cached: fine (probe is unconstrained there);
  #   - constrained only on probe: NOT a subset (cached is unconstrained
  #     there, so cached admits rows probe rejects).
  attrs =
    MapSet.union(
      MapSet.new(Map.keys(cached_disjunct)),
      MapSet.new(Map.keys(probe_disjunct))
    )

  Enum.all?(attrs, fn attr ->
    case {Map.fetch(cached_disjunct, attr), Map.fetch(probe_disjunct, attr)} do
      {{:ok, cached_interval}, {:ok, probe_interval}} ->
        interval_subset?(cached_interval, probe_interval)

      {{:ok, _cached_interval}, :error} ->
        true  # probe doesn't constrain this attr; cached's constraint is fine

      {:error, {:ok, _probe_interval}} ->
        false  # cached is unconstrained here; it cannot be a subset
    end
  end)
end
```

### 3. Interval subset primitives

Implement `interval_subset?/2` case by case:

- `:opaque` → always `false`.
- `%Interval{op: :eq, values: [v]}` subset of another interval iff `v` is
  contained by that interval.
- `%Interval{op: :in, values: vs}` subset of another interval iff every `v` in
  `vs` is contained.
- `%Interval{op: :range, lower: l1, upper: u1}` subset of
  `%Interval{op: :range, lower: l2, upper: u2}` iff `l2 ≤ l1` and `u1 ≤ u2`
  (respecting inclusive/exclusive flags).
- `%Interval{op: :is_nil}` subset only of another `:is_nil`.
- `%Interval{op: :not_eq, values: [v]}` subset of another interval iff `v` is
  the only excluded value and the other interval excludes `v` (narrow; start
  conservative).

Each case has explicit unit tests.

### 4. Comparisons across mixed types

If `cached_interval.type != probe_interval.type`, return `false` (conservative).
Type mismatches shouldn't happen if the normaliser is correct, but defence in
depth.

## Files to Create/Modify

- `lib/ash_multi_datalayer/coverage/implication.ex` — new.
- `test/ash_multi_datalayer/coverage/implication_test.exs` — new; unit tests for
  each case.

## Patterns to Follow

- `Ash.Filter` module for AST walking conventions.
- For interval containment: be explicit about inclusive/exclusive bounds; don't
  trust `<=` vs `<`.

## Acceptance Criteria

- [ ] `implies?(F, F)` is `true` on every normalised filter (reflexivity).
- [ ] `implies?(A, B) and implies?(B, C)` implies `implies?(A, C)` on
      handwritten triples (transitivity sanity check).
- [ ] Narrower `eq` implies broader `eq`/`in`/`range`.
- [ ] Narrower `range` implies broader `range`.
- [ ] `in` with smaller value set implies `in` with larger value set (on same
      attribute).
- [ ] Disjunction: `A OR B implies C` iff `A implies C` AND `B implies C`.
- [ ] Type mismatch → `false`.
- [ ] Any `:opaque` in cached → `false`.

## Definition of Done

- [ ] Code compiles with no warnings
- [ ] Tests pass (new + existing)
- [ ] Acceptance criteria verified
- [ ] `mix dialyzer` clean on this module
- [ ] No known regressions introduced

## Verification

```bash
cd /home/joba/sandbox/ash_multi_datalayer
mix test test/ash_multi_datalayer/coverage/implication_test.exs
mix dialyzer
```

## Notes

- **Correctness before completeness.** If in doubt about a specific interval
  relationship, return `false`. The property suite in Task 13 will catch
  soundness regressions; incompleteness just causes cache misses.
- Run the full file through `mix credo --strict` — this is the correctness core;
  it deserves extra scrutiny.
- Do NOT short-circuit `implies?/2` with early wins that skip attributes; every
  attribute constraint on **either** side must be checked (see the warning on
  `attrs_subset?/2` above). Missed attributes are the subtlest soundness bugs.
- **Negation semantics** (implementation experience, 2026-07-03): Ash's runtime
  match semantics are neither classical nor Kleene-compositional — a comparison
  with a `nil` operand evaluates to `nil`, a bare `not` propagates `nil`, but
  `or` collapses `nil` to `false`. Classical operator duals and De Morgan
  rewriting under `Not` are therefore **unsound**; the implementation treats
  `Not` as opaque except directly over `is_nil` (the only always-boolean
  predicate). Both this and the `attrs_subset?/2` union bug were caught by the
  10 000-case property suite cross-checking against `Ash.Filter.Runtime`.
