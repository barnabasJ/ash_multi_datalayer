# L10 — Doc/code contradictions introduced by this work

- **Status**: OPEN
- **Severity**: Low (docs)
- **Repo**: MDL (ash_multi_datalayer)
- **Verification**: VERIFIED
- **Source**:
  [20260707 implementation review — L10](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Files**:
  `lib/ash_multi_datalayer/orchestrator/local_outbox/write.ex:230-233`,
  `local_outbox.ex:222-229`, `backfill.ex` moduledoc/@doc

## Defects

1. `write.ex:230-233` comment asserts "there is no background sweeper" while
   `local_outbox.ex:222-229` starts one.
2. `backfill.ex` moduledoc/@doc claim `default_fields` writes "ALL resource
   attributes — including `%Ash.NotLoaded{}`" while `default_fields/2` now
   filters NotLoaded out.

## Fix

Update both comment/doc sites to match the shipped behavior (or whatever
behavior the sweeper/fields tasks settle on — do this **after**
[L5](l5-sweeper-global-name-multinode.md) and the A6-adjacent work stabilize).

## Done when

- [ ] Both contradictions resolved against final behavior
- [ ] Docs sweep re-checked for other comments referencing the sweeper /
      default_fields semantics
- [ ] `INTEGRATION=1 mix test` green in MDL (doctests/moduledoc changes compile)
