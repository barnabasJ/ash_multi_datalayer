# B5 — `validate_aggregate_overrides` compile regression breaks legitimate configs

- **Status**: OPEN
- **Severity**: Blocker (compile failure on valid config)
- **Repo**: MDL (ash_multi_datalayer)
- **Verification**: VERIFIED
- **Source**:
  [20260707 implementation review — B5](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Original finding**: none — regression introduced by over-reaching plan A7
  item 6
- **Files**:
  `lib/ash_multi_datalayer/verifiers/validate_aggregate_overrides.ex:30`

## Defect

The verifier loop validates `local_evaluation_overrides` against
`Ash.Resource.Info.aggregates/1` names, but that option holds **calculation**
names (`data_layer.ex:149` doc: "Calculation names…"; consumed at
`value_merge.ex:57` as `calculation.name not in overrides`).

## Failure scenario

Any resource declaring `local_evaluation_overrides [:overdue?]` (a calculation)
fails compilation: "`[:overdue?]` … is not an aggregate on this resource." The
example app happens to avoid it, so suites stayed green.

## Fix

Validate `local_evaluation_overrides` against **calculation** names; keep the
two aggregate-override options (`fold_aggregate_overrides`, etc.) validated
against aggregate names.

## Compile-posture note (technical review F3 / spec review)

The Spark verifier "rejection" is only a hard failure under
`--warnings-as-errors` — under plain `mix compile` it downgrades to `IO.warn`
(that is the whole of [P2](p2-verifier-compile-posture.md)). So the repros below
must not assert on plain-`mix compile` behavior, which would pass or fail for
the wrong posture reason. Follow the existing verifier tests
(`test/ash_multi_datalayer/verifiers_test.exs`) and **call
`ValidateAggregateOverrides.verify/1` directly** (or run an explicit
`--warnings-as-errors` compile), so the assertion is about the verifier's
verdict, not the compile posture. This task's rejection guarantee is bounded by
P2; note that dependency.

## Done when

- [ ] Repro test: a resource with `local_evaluation_overrides [<calc name>]`
      passes the verifier — fails on unfixed code by returning a `DslError` for
      "not an aggregate" (asserted via `verify/1` directly, per the posture
      note)
- [ ] Typo tests still reject an unknown name in each of the three option groups
      (calc names for `local_evaluation_overrides`, aggregate names for the
      aggregate options) — asserted via `verify/1`, not plain `mix compile`
- [ ] `INTEGRATION=1 mix test` green in MDL
