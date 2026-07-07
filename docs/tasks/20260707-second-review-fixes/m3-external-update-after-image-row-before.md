# M3 — External update notification passes the after-image as `row_before` (A2)

- **Status**: OPEN
- **Severity**: Medium (stale cached row survives under live entry)
- **Repo**: MDL (ash_multi_datalayer)
- **Verification**: VERIFIED
- **Source**:
  [20260707 implementation review — M3](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Original finding**: A2 (second review)
- **Plan ref**: Workstream A phase A3 item 3
- **Files**: `lib/ash_multi_datalayer/orchestrator/proven_coverage.ex:172-183` +
  `ash_multi_datalayer.ex:53-61` (`forget_probe`)

## Defect

External update notifications route the full after-image record to `forget!`,
whose `forget_probe(resource, %resource{} = record) -> record` clause passes it
verbatim as `row_before` to
`Invalidation.on_write(resource, tenant, record, nil)`. The plan required a
PK-only **unknown** before-image (and `forget_probe` already builds one for a PK
map).

## Failure scenario

A row flips `status: :active → :archived`; the notification's `data` is the
archived after-image; a ledger entry covering `status == :active` is evaluated
against `:archived` → not dropped → the stale `:active` cached row survives
under a live covering entry.

## Fix

Make `forget_probe`'s `%resource{}` clause (`ash_multi_datalayer.ex:61`)
**delegate to its PK-map clause** so it builds a PK-only _unknown_ probe instead
of returning the record verbatim, e.g.
`def forget_probe(resource, %resource{} = record), do: forget_probe(resource, Map.take(record, Ash.Resource.Info.primary_key(resource)))`.
Then `row_before` passed to `on_write/4` is PK-only-unknown and the covering
entry is dropped (the predicate can't be evaluated against a known value, so it
conservatively invalidates).

**Scope guard (both round-6 reviews)**: this is a one-_clause_ change, not a
one-liner, and it does **not** touch the after-image. `forget!/3` calls
`Invalidation.on_write(resource, tenant, row_before, nil)` — the 4th arg stays
`nil` on purpose (the drop-then-refetch posture that is sound under at-most-once
delivery; see `proven_coverage.ex:168-170`). Do **not** change the `forget!/3` /
`handle_external_change/2` API to pass a `row_after`; the defect is fully fixed
by the PK-only before-image alone.

## Done when

- [ ] Repro test — the **A2 scenario** of plan A0 repro 20 (a bundled A2–A5 slot
      at `plan:118-121`, NOT a single test; this task owns A2, L4 owns A3):
      filter-movement scenario above drops the covering entry — fails on unfixed
      code by keeping it. Add as a distinct test/assertion; do not clobber L4's
      A3 scenario file
- [ ] The after-image (4th arg of `on_write/4`) remains `nil` — no `forget!/3`
      API change
- [ ] `INTEGRATION=1 mix test` green in MDL
