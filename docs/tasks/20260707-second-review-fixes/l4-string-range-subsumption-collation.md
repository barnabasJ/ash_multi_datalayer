# L4 — String/CiString range subsumption still byte-ordered (A3)

- **Status**: OPEN
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
