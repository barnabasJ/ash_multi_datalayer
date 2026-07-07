# Review: the 2026-07-06 review-findings fix plan (pass 4 / round 3)

**Date**: 2026-07-06 **Input**: the plan after its round-2 amendments (now four
passes deep — [pass 1](./20260706-review-findings-fix-plan-review.md), [pass 2](./20260706-fix-plan-review.md),
[pass 3](./20260706-fix-plan-review-pass3.md), [round 2](./20260706-review-findings-fix-plan-review-2.md)),
re-verified against source. **Verdict**: implementation-ready. The round-2
amendments I could check are sound — the rebase cleanup-transaction posture is
feasible, the A3 batched ledger scan and the per-site resource-map key are
correct. One substantive issue: the A1-2 **force-back** (round-2 W1's fix for a
"double evaluation" hole) is almost certainly redundant — the Ash create
pipeline already evaluates lazy defaults before the data layer, and `set_defaults`
is idempotent — and the plan's own Facts note says so, contradicting A1-2's
justification. It's harmless, but it's needless machinery built on a premise
that doesn't hold. The A0-2 lazy-default test should be allowed to settle it.

As before, every claim is verified against source. Severities: **warning** =
reasoning flaw that adds needless complexity or an internal contradiction;
**suggestion** = cleanup.

---

## Warning

### W1 — A1-2's force-back is redundant: the pipeline pre-sets lazy defaults, and `set_defaults` is idempotent

A1-2 (lines 136-142) says to "force the materialized values back into the
changeset … the local data layer calls `apply_attributes` again itself (verified:
ETS create does), so without the force-back, lazy defaults would be evaluated
twice and the target and local rows would differ in PK/timestamps." The premise —
that `&Ash.UUID.generate/0`/`&DateTime.utc_now/0` get evaluated once in
write_through's `apply_attributes` and **again** in ETS create's — does not hold
for a write_through reached through the normal `Ash.create` pipeline, which is
the only way write_through is reached (it's a changeset-context flag processed by
`Ash.create`/`update`).

The mechanism, traced through Ash 3.29.3:

1. **The pipeline evaluates lazy defaults before the data layer.** `create.ex:277`
   runs `Ash.Changeset.set_defaults(:create, true)` in the `changeset/4` helper,
   unconditionally (both branches of the `__validated_for_action__` guard pipe
   through it), before `commit/3` invokes the data layer. `set_defaults(_, _,
   true)` calls `set_lazy_defaults`, which **evaluates** the default function
   (`changeset.ex:4170`, `function.()`) and `force_change_attribute`s the result
   onto the changeset. So by the time `Write.run → write_through` runs, `:id` /
   timestamps are already concrete values in `changeset.attributes`.
2. **`set_defaults` is idempotent.** Every default path — static
   (`changeset.ex:4084`, `:4109`), lazy-non-matching (`:4142`), and
   lazy-matching (`:4177`) — is guarded by `if changing_attribute?(changeset,
   attribute.name)`. `changing_attribute?/2` is `Map.has_key?(changeset.attributes,
   name) || …` (`changeset.ex:6423`). Once the pipeline has set `:id`, the guard
   is true, so both write_through's `apply_attributes` (`changeset.ex:7566`,
   which calls `set_defaults(..., true)`) and ETS create's `apply_attributes`
   (`ets.ex:1700`) **skip** it. The lazy default is evaluated exactly once (in the
   pipeline), not twice.

So both sides — the target push and the local commit — already see the same
concrete UUID-A; the force-back re-sets `:id` to the value it already has. It is
a no-op, not a fix.

This is also a **self-contradiction in the plan**: the Facts section (lines
437-438) states "Ash's create pipeline calls `Ash.Changeset.set_defaults(:create,
true)` before the data layer, so defaults exist on the changeset pre-commit" —
which is precisely why the "evaluated twice" premise is wrong. The same body of
text asserts both that defaults exist pre-commit and that they'd be evaluated
twice without intervention.

**What to do.** This is harmless (an idempotent re-set), so it won't cause
incorrect behavior. But the A0-2 materialization test should be run **both with
and without** the force-back on a resource with a lazy-defaulted PK and a
lazy-defaulted timestamp: if it passes without the force-back (the expected
outcome, per the trace above), drop the force-back as needless complexity and
fix the A1-2 justification + the contradiction. If it somehow fails without the
force-back, that means write_through is reachable on a changeset whose lazy
defaults were *not* pre-set — keep the force-back and document the path (that
would be the genuinely load-bearing finding). Either way, let the test decide
rather than shipping speculative machinery.

(Note: round-2 W1 was right that ETS create re-calls `apply_attributes`
(`ets.ex:1700`, confirmed) — the missing step in that analysis was checking
*whether the second call re-evaluates*, which the `changing_attribute?` guard
prevents once the pipeline has run.)

---

## Suggestions

### S1 — Facts note typo: stray space in the transformer path
Line 430: `` `sync/transformers/ inject_outbox.ex` `` has a space before
`inject_outbox`. Cosmetic, but this body of text is now an implementation
checklist.

### S2 — A1-1: name the transaction mechanism concretely
Step (c) says "inside one outbox-repo transaction" — feasible (the outbox is
`AshSqlite`, and `Ash.DataLayer.transaction/5` exists, `data_layer.ex:522`), but
"outbox-repo transaction" is ambiguous between `Ash.DataLayer.transaction(outbox,
…)` and a raw `repo.transaction(…)`. Name the call so the implementer doesn't
hand-roll the wrong one (the entries are destroyed via `Ash.destroy!(…, action:
:discard)`, which must run *inside* the `Ash.DataLayer.transaction` for the
rollback to cover them). The failure posture itself (transaction → on failure
nothing destroyed, fresh chain sits `:blocked`, distinct error, recovery via
`discard/1`) is sound and preserves invariant 1.

---

## Round-2 amendments — confirmed sound (verified)

- **A1-1 cleanup-transaction posture (round-2 W2):** feasible and correct. With
  the apply (step b) committed before the cleanup transaction (step c), a cleanup
  failure leaves the resolution applied + fresh entries `:blocked` behind the
  intact parked head — no divergence, no lost evidence — and `discard/1` (which
  re-reads and destroys the chain) unblocks. The "destroy-by-ID is idempotent"
  claim holds because recovery re-derives the chain rather than trusting stale
  IDs.
- **A3 batched ledger scan (pass-3 S1 → `Invalidation.on_evict/3`):** correct —
  collect ghosts, scan `Coverage.entries/2` once, drop any entry matching any
  ghost, bump once. This is the right shape and removes the O(ghosts × ledger)
  cost without changing semantics.
- **B1-2 per-site resource-map key (round-2 S1):** the tagged key
  `{AshRemote.Server, :resource_map, otp_app, :rpc | :channel}` correctly
  prevents one resolver overwriting/reusing the other's map (the two sites check
  `resources/1` vs the published set — genuinely different). Sound.
- **The atomic-capability-delegation RFC** referenced as a follow-up exists
  (`docs/design/20260706-atomic-capability-delegation-rfc.md`), is correctly
  sequenced after A5, and its interaction with A1-2's atomics guard (keep the
  rejection) is noted. Appropriately out of scope.

---

## Summary

**0 critical, 1 warning, 2 suggestions.** The plan is implementation-ready. The
only substantive note is W1: the A1-2 force-back is built on a "double
evaluation" premise that the Ash create pipeline already precludes (verified:
`create.ex:277` sets lazy defaults pre-data-layer, and `set_defaults` is
idempotent via `changing_attribute?`), and the plan's own Facts section
contradicts it. Let the A0-2 lazy-default test arbitrate — run it without the
force-back first; the expected result is a pass, at which point drop the
force-back and reconcile the contradiction. Everything else from round 2
(cleanup-transaction posture, batched reconcile scan, per-site map key) checks
out against source.
