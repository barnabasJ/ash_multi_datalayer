# P2 — Verifier "rejections" don't block a plain `mix compile` (Spark downgrade)

- **Status**: DONE — posture decided: **docs-only** (no new runtime guard; a
  runtime guard for the field-policies case specifically would be a materially
  larger, riskier change — re-implementing part of what the compile-time
  verifier already checks — for a project that already documents
  `--warnings-as-errors` as the fix). README gained a "Compile-time DSL checks
  require `--warnings-as-errors`" section spelling out the
  Spark-2.7-downgrades-verifier-rejections-to-warnings behavior, linking the
  field-policies ADR, and giving the exact compile flag. New end-to-end test
  pins the posture for the field-policies rejection specifically: it compiles
  the offending config without raising (proving the "silently accepted" half)
  AND captures the diagnostic via Spark's `:test_collector` test hook (proving
  the "reaches the compiler diagnostic path a `--warnings-as-errors` build
  enforces" half) — mirrors the file's existing `ValidateLayers` end-to-end test
  for the general mechanism. Note: `assert_receive` against this specific
  message shape (a struct nested inside a list inside a 4-tuple) reliably failed
  to match a message plainly visible in its own failure-report mailbox dump —
  root cause not chased down given time; a plain `receive/after` block with the
  same pattern (as a case clause, not a receive guard) works reliably.
  `INTEGRATION=1 mix test` green (316, up from 315).
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
