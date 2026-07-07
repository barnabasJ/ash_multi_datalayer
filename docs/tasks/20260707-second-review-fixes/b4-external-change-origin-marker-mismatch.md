# B4 — ExternalChange origin marker matches no real notification → realtime invalidation dead

- **Status**: DONE — `replayed_external?/1` now normalizes both key levels
  (`Map.get(metadata, "ash_remote") || Map.get(metadata, :ash_remote)`, then the
  same for `origin`) instead of two shape-specific clauses, so it matches the
  real producer's mixed string-outer/atom-inner shape. The dead
  `external?: true` clause (no known producer) is removed. Repro built from the
  exact shape in `ash_remote/lib/ash_remote/realtime/inbound.ex`'s `metadata/1`;
  fails on unfixed code (confirmed) by dropping the notification. Both existing
  synthetic-shape tests (all-string, all-atom) kept and still pass.
  `INTEGRATION=1 mix test` green (289).
- **Severity**: Blocker (permanent silent staleness)
- **Repo**: MDL (consumer) — producer shape defined in ash_remote
- **Verification**: VERIFIED
- **Source**:
  [20260707 implementation review — B4](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Original finding**: #21
- **Plan ref**: Workstream A phase A7 item 1
- **Files**: `lib/ash_multi_datalayer/notifiers/external_change.ex:72-80` (all
  three clauses — the third, `external?: true`, is at line 80) vs producer
  `../ash_remote/lib/ash_remote/realtime/inbound.ex:156`

## Defect

`replayed_external?/1` has **three** positive clauses
(`external_change.ex:72-80`, verified 2026-07-07):

1. all-string `%{"ash_remote" => %{"origin" => _}}`
2. all-atom `%{ash_remote: %{origin: _}}`
3. `%{metadata: %{external?: true}}`

The producer emits
`Map.put(user_meta, "ash_remote", %{origin: :remote, id: ..., occurred_at: ...})`
— **string outer key, atom inner keys** — which matches neither clause 1 nor 2,
falls to `_ -> false`, and the notification is dropped.

**Clause 3 is also dead**: grep across both repos and the examples finds **no
producer that sets `external?: true`** — so all three marker paths fail to fire
for the actual producer, not just the two ash_remote-shape clauses (technical
review F1).

The two adapted tests use synthetic all-string (`external_change_exit_test.exs`)
and all-atom (`local_outbox_test.exs`) shapes — each passes one clause; the real
mixed shape passes none.

## Failure scenario

A peer writes a row; the replayed external notification is dropped →
`handle_external_change` never runs → coverage invalidation / local refresh
never happens → **permanent silent staleness on every externally-replayed
change**. Original finding #21 (react only to external writes) was
over-corrected into reacting to nothing.

## Fix

Match the real producer shape (string outer key, atom inner key), and/or
normalize metadata keys before matching. Best: share/assert the marker shape
between producer and consumer so they cannot drift again. **Decide each of the
three clauses explicitly** — do not "fix" clause 1/2 and leave clause 3 as an
unreached path that looks intentional (F1): either delete the `external?: true`
clause if no producer is meant to set it, or wire a producer to set it (e.g. a
non-realtime external trigger) and add a retained test for that path.

## Done when

- [ ] Repro test uses the **actual producer-emitted metadata shape** (ideally
      constructed by calling the producer code path, not hand-built) — fails on
      unfixed code because the notification is dropped
- [ ] Test that local (non-replayed) notifications are still ignored (#21's
      original requirement holds)
- [ ] The `external?: true` clause is either removed, or exercised by a test
      with a real producer that sets it (no dead marker path left behind)
- [ ] Existing synthetic-shape tests updated to the real shape or kept in
      addition
- [ ] `INTEGRATION=1 mix test` green in MDL
