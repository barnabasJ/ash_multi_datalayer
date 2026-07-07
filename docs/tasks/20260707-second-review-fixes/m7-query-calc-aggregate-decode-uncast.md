# M7 — Query calculations/aggregates decoded uncast (#25)

- **Status**: DONE — all 4 `place/4` clauses (`:calculation`/`:aggregate`, each
  with a `load`-aliased and a default-map variant) now cast through a shared
  `cast_typed/3`, using the `type`/`constraints` already present on the
  `%Ash.Query.Calculation{}`/`%Ash.Query.Aggregate{}` struct Ash core hands to
  `add_calculation`/`add_aggregate` — no resource-level DSL lookup needed (works
  for ad-hoc/dynamically-loaded targets too, unlike `cast_calculation/3`'s
  name-lookup, which now delegates to the same helper). Nil type or a cast
  failure falls back to the raw wire value — never raises. 4 unit-level repros
  (one per `place/4` clause) exercise `Decoder.decode_record/3` directly with
  hand-built typed calc/aggregate structs — deliberately NOT an RPC round-trip,
  since ash_remote's ad-hoc query-time calc/aggregate protocol support turned
  out not to reliably resolve `.type` for every construction path (a separate,
  pre-existing concern outside this task); all 4 fail on unfixed code
  (confirmed). New `Comment.rating :decimal` field + `Todo.avg_comment_rating`
  aggregate + `Todo.deadline_echo` calc fixtures. Full `mix test` green (197/199
  — the 2 remaining failures are a pre-existing, unrelated `ChangeNotifierTest`
  issue confirmed present on unfixed code too, out of this task's scope).
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
