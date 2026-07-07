# P2 — Verifier "rejections" don't block a plain `mix compile` (Spark downgrade)

- **Status**: OPEN — re-verified 2026-07-07: no `--warnings-as-errors` mention
  anywhere in README or docs/guides
- **Severity**: Medium (security-adjacent: field-policies rejection is advisory)
- **Repo**: MDL (ash_multi_datalayer)
- **Source**:
  [20260704 implementation review — M4](../../reviews/20260704-implementation-review.md)
  (added per
  [task-coverage review F2](../../reviews/20260707-second-review-fixes-task-coverage-review.md))
- **Files**: all `lib/ash_multi_datalayer/verifiers/*`; Spark 2.7
  `__verify_spark_dsl__` catches its own `DslError` raise and downgrades it to
  `IO.warn`

## Defect

Every MDL verifier "rejection" — including the `field_policies` +
multi-layer-`read_order` case the ADR
(`20260417-reject-field-policies-with-fallthrough-adr.md`) promises "fails to
compile" — **compiles with a warning and runs** under plain `mix compile`,
serving cache rows materialized under a different actor without redaction. Same
for tenant-incapable layers on multitenant resources, non-upsert cache layers,
and the new authority-order verifier (#22). There is no runtime guard, and no
consumer-facing doc says `--warnings-as-errors` is required for the rejections
to actually block.

This matters _more_ now: B5's compile "regression" and the #22 verifier are only
as strong as this posture.

## Fix

Per the original review's options: document + recommend `--warnings-as-errors`
prominently (README + guide); and/or add a cheap runtime guard for the
field-policies case (the security one); plus a test pinning the posture (the
diagnostic fails under `--warnings-as-errors`).

## Done when

- [ ] Posture decided and recorded (docs-only vs runtime guard for
      field-policies)
- [ ] README/guide state the `--warnings-as-errors` requirement
- [ ] Test pins the posture for at least the field-policies rejection
- [ ] `INTEGRATION=1 mix test` green in MDL
