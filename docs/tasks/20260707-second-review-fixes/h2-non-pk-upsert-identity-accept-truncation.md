# H2 — Non-PK upsert identity ignored + accept-list truncation (#24)

- **Status**: OPEN
- **Severity**: High (silent replica divergence)
- **Repo**: ash_remote
- **Verification**: AGENT
- **Source**:
  [20260707 implementation review — H2](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Original finding**: #24
- **Plan ref**: Workstream R phase R3 item 4
- **Files**: `../ash_remote/lib/ash_remote/data_layer.ex:198,243-247,367`

## Defect

Two halves:

1. `upsert/3` ignores its `keys` arg (`def upsert(resource, changeset, _keys)`);
   `remote_pk_row/2` resolves solely by primary key, so a non-PK
   `upsert_identity` mis-resolves.
2. The update path's `input/1` still does `Map.take(attributes, accepted_keys)`
   where `accepted_keys = action.accept`, so a replicated write carrying more
   fields than the update action accepts converges only those fields **and
   returns success**.

   **Scope note (source-audit B-3)**: `accepted_keys/1`
   (`data_layer.ex:369-371`) falls back to **all attributes**
   (`Ash.Resource.Info.attributes/1` at `:370` — including `public? false` ones,
   NOT just public; loop-1 correction) when the action has no explicit `accept`
   list — so truncation only bites when `action.accept` IS set. The action-less
   backfill/replication path is already safe; the fix targets the
   explicit-accept case.

## Failure scenario

A resource with a non-PK `upsert_identity` mis-resolves and surfaces a
collision; a LocalOutbox→AshRemote replicated write produces a divergent replica
with a success return (silent divergence).

## Fix

Per plan R3 item 4: build the upsert lookup filter from `keys`, not only primary
key. This applies to **both** `remote_pk_row` lookups in the upsert flow — the
initial one (`data_layer.ex:199`) **and** the post-create-collision retry lookup
inside `create_or_retry_as_update` (`data_layer.ex:211-214`), plus the
`put_write_action(_, _, :update)` data resolution (`:230-239`), all of which
currently key by primary key only (pass-6 review).

For the accept-list half: the truncation bites only when the resolved update
action has an **explicit `accept`** list (`accepted_keys/1` at `:369-371` falls
back to **all attributes** — incl. `public? false` — otherwise). The fix is that
a **replicated/backfill update must converge all provided fields regardless of a
user update action's `accept`**, while an ordinary action-driven update still
respects `accept` — frame the split on "replicated write" vs "user action", not
on "action-less".

## Done when

- [ ] Repro test: non-PK identity upsert resolves the existing row — fails on
      unfixed code (collision / wrong row)
- [ ] The create-collision **retry** lookup also builds its re-read filter from
      `keys` (not primary key only) — tested, not just the initial lookup
- [ ] **Update by the found row's actual PK (pass-7 High)**: after the non-PK
      identity lookup finds the existing row, both the initial update path and
      the collision-retry path update by **that row's PK**, not a PK rebuilt
      from incoming changeset attributes (`put_write_action(_, _, :update)` at
      `data_layer.ex:230-239` currently rebuilds from attributes). Repro:
      incoming changeset lacks/wrong PK but matches an existing row by non-PK
      identity → the update targets the found row, not a missing/stale PK
- [ ] Repro test: replicated update with fields outside the update action's
      explicit `accept` converges all fields — fails on unfixed code by
      truncating
- [ ] Ordinary action-driven updates still respect `accept`
- [ ] Full `mix test` green in `../ash_remote`
