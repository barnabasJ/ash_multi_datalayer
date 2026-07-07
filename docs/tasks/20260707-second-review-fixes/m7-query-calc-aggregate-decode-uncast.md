# M7 — Query calculations/aggregates decoded uncast (#25)

- **Status**: OPEN
- **Severity**: Medium (typed matches break; cache layers poisoned)
- **Repo**: ash_remote
- **Verification**: VERIFIED
- **Source**:
  [20260707 implementation review — M7](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Original finding**: #25
- **Plan ref**: Workstream R phase R3 item 5
- **Files**: `../ash_remote/lib/ash_remote/decoder.ex:61-77`

## Defect

`decoder.ex` is untouched by the fix run. `place/4` for `{:calculation, calc}` /
`{:aggregate, agg}` `Map.put`s the raw wire value; `cast_calculation/3` is wired
only to the remote-calc-meta / bundle paths, not the ordinary read-plan targets.

## Failure scenario

A `:date` query calculation yields a String, a decimal `:sum` aggregate yields a
String → downstream `%Date{}`/`%Decimal{}` matches break, and MDL cache layers
are poisoned with wrongly-typed values.

## Fix

Cast decoded query calculations and aggregates using their declared types (plan
R3 item 5) — wire `cast_calculation/3` (and an aggregate equivalent) into the
ordinary read-plan `place/4` targets. **Cover every `place/4` clause** (pass-6
review): `decoder.ex:61-77` has separate calculation and aggregate clauses with
`load`/alias placement that also `Map.put` the raw value — casting only the
default `:calculations`/`:aggregates` map clauses would leave loaded/aliased
targets uncast.

## Done when

- [ ] Repro test: date calc and decimal sum aggregate decode to `%Date{}` /
      `%Decimal{}` — fails on unfixed code with strings
- [ ] Coverage for **aliased/`load`-placed** calc and aggregate targets, not
      only the default `:calculations`/`:aggregates` maps
- [ ] Nil and error values pass through safely
- [ ] Full `mix test` green in `../ash_remote`
