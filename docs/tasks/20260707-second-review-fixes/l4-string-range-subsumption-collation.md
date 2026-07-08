# L4 — String/CiString range subsumption still byte-ordered (A3)

- **Status**: DONE — `Interval.subset?/2` gained a clause for `kind: :range`
  intervals whose `type` is `Ash.Type.String` or `Ash.Type.CiString`:
  subsumption now requires the two ranges' bounds to be identical
  (`inner.lower == outer.lower and inner.upper == outer.upper`), refusing the
  general `lower_within?`/`upper_within?` byte-order comparison for these types.
  Equality/`in` handling (`:eq`/`:in` route through `contains_value?/2`,
  unaffected) stays as is, per the task's scope. 2 repro tests in
  `subsumption_test.exs`: `name > "B"` no longer (falsely) subsumes `name > "b"`
  — confirmed via stash to serve incorrectly from cache on unfixed code
  (`pg_reads()` stayed 1 instead of going to 2); a same-bound re-query
  (`name > "aardvark"` twice) still subsumes correctly (unaffected,
  byte-order-independent). Interval property tests still pass (no regressions).
  `INTEGRATION=1 mix test` green (322, up from 320).
- **Severity**: Low (silently dropped rows under ICU collation)
- **Repo**: MDL (ash_multi_datalayer)
- **Verification**: AGENT
- **Source**:
  [20260707 implementation review — L4](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Original finding**: A3 (second review)
- **Plan ref**: Workstream A phase A3 item 4
- **Files**: `lib/ash_multi_datalayer/coverage/interval.ex` (untouched by the
  fix run)

## Defect

`interval.ex` was not changed: string/CiString range subsumption is still
byte-ordered. `name > "B"` falsely subsumes `name > "b"` under ICU collation →
rows silently dropped from covered reads.

## Fix

Per plan A3 item 4: refuse string/CiString range subsumption for `<`, `<=`, `>`,
`>=` unless the bounds are equal (or a future explicit C-collation option is
configured). Equality/`in` handling stays as is.

## Done when

- [ ] Repro test — the **A3 scenario** of plan A0 repro 20 (a bundled A2–A5 slot
      at `plan:118-121`, NOT a single test; M3 owns the A2 scenario, this task
      owns A3): `> "B"` does not subsume `> "b"` — fails on unfixed code. Add as
      a distinct test/assertion; do not clobber M3's A2 scenario file
- [ ] Interval property tests still pass
- [ ] `INTEGRATION=1 mix test` green in MDL
