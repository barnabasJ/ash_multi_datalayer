# Review (round 4): 2026-07-06 review-findings fix plan

**Date**: 2026-07-06 **Scope**:
`docs/plans/20260706-review-findings-fix-plan.md` after the round-3 amendments.
Method: (1) checked every Round-3 disposition entry against the three round-3
reviews (the consolidated round3, pass 4, review-3) for faithfulness — including
the one cross-pass conflict the plan had to adjudicate; (2) re-verified against
source each claim the amendment newly introduced (the `discard/1` branch
structure, `Ash.DataLayer.transaction`, the `connect_params` init comment, the
hydrate modes); (3) fresh-eyes pass over the rewritten sections. Round-3's
source verification (both repos + deps/ash 3.29.3) still stands and was not
redone.

## Verdict

**Implementation-ready. 0 criticals, 0 warnings, 2 suggestions, 3 nits.** All
sixteen round-3 findings across the three passes are present in the disposition
and genuinely folded into the plan text — nothing was dropped or watered down.
The one adjudication the plan had to make on conflicting reviews (`discard/1`
idempotency: pass 4 said it holds, the consolidated review said it doesn't) was
decided **correctly, by source**: `Api.discard/1`'s `:create` branch re-derives
the chain via `record_chain(entry)` (a second call finds an empty chain —
effectively idempotent), but the non-create branch runs `Ash.destroy!` on the
passed struct and raises on a second call — and a parked conflict head is
typically an update/destroy op, so the recovery path hits exactly the
non-idempotent branch. Making idempotency an A1 deliverable with double-discard
coverage is the right resolution. The two suggestions below are internal
consistency slips introduced by the amendment itself, not design issues; this
plan has converged.

## Newly-introduced claims — verified

- **`discard/1` branch structure** (Facts, disposition Round-3 W3): confirmed at
  `orchestrator/local_outbox/api.ex` — `:create` → `record_chain` +
  `Enum.each(Ash.destroy!)`, returns
  `{:ok, %{discarded: n, dropped_chain: true}}`; non-create →
  `Ash.destroy!(entry, ...)` on the passed struct. The plan's adjudication text
  matches the code exactly.
- **`Ash.DataLayer.transaction(outbox, ...)`** (A1-1c, from pass 4 S2): exists —
  `deps/ash/lib/ash/data_layer/data_layer.ex:522-556` (single-resource and
  resource-list heads, arity 5 with defaults). Right mechanism for wrapping the
  `Ash.destroy!(…, action: :discard)` calls.
- **The misleading "per connect" comment** (B2-3): confirmed —
  `ash_remote/lib/ash_remote/realtime/connection.ex` `init/1` comments
  "connect_params (e.g. an auth token) are evaluated per connect" directly above
  the single `eval(opts.connect_params)` that runs once per process. B2-3's
  drive-by comment fix is warranted.
- **Hydrate modes for A0-7**: confirmed — `local_outbox.ex:148` validates
  `hydrate:` against `[:if_empty, :on_start, :manual]`; the two modes A0-7
  exercises are the two whose boot path A1-4 touches.
- **Pass 4 S1 (stray space in the transformer path)**: fixed — the Facts bullet
  now reads `sync/transformers/inject_outbox.ex`.

## Findings

### S1 [suggestion] The A0 gate says tests 1–6 fail, but A0-2's materialization sub-assertion passes today (plan lines 73–81, 121–122)

Pre-fix, `write_through/3` pushes **`local_write`'s return value** to the
targets (`write.ex:48-49`) — the target receives the exact record the local
layer holds, so "assert the record the target received equals the record the
local layer holds" is true **by construction** before any fix. It is also
expected to pass after the A1-2 reorder (that's its arbitration role: it only
fails if some path reaches write_through without pipeline pre-materialization).
A sub-assertion that is green before and green after cannot be part of a gate
that reads "tests 1–6 fail for the review's stated reasons," and "it gates the
A1-2 reorder" (line 77) overstates it for the same reason. Two-word-level fix:
exempt the materialization sub-assertion in the gate line the same way A0-7/A0-8
are exempted ("gap-filling/arbitration — expected green pre-fix, must stay green
post-fix"), and say it _regression-protects_ the reorder rather than gates it.
A0-2's first half (action errors AND local unchanged) is the genuine pre-fix
failure and carries the gate.

### S2 [suggestion] The Facts bullet still carries the imprecise `apply_result/6` phrasing that A2-1(b) corrected (plan lines 505–506 vs 231–234)

A2-1(b) now says, correctly, that `apply_result/6`'s **`{:error, _}` clause**
branches only on `:rejected`/`:transient` and that the function also has `:ok`
and `{:conflict, _}` clauses. The Facts section still states the round-2 form —
"`apply_result/6` branches only on `:rejected`/`:transient`" — the exact wording
round 3 flagged as misleading. Since the Facts section is the implementation
checklist's ground truth, align it with A2-1(b) (or delete the clause-count
detail from Facts and let A2-1(b) own it).

### Nits

- **Line 80: mangled emphasis** — "the pipeline did \\_not\\*" is corrupted
  markup (should be `*not\*`). Same sentence also has an unbalanced `_…\*` pair;
  a formatter artifact from the amendment.
- **A1-1c: say the transaction re-raises and `rebase/2` must rescue-and-wrap.**
  `Ash.destroy!` raising inside `Ash.DataLayer.transaction` rolls the
  transaction back and **re-raises** — the "return a structured error carrying
  the underlying cause" posture therefore requires a rescue at the `rebase/2`
  boundary converting the raise into that error. It's implied; one clause makes
  it explicit so the raise doesn't escape `rebase/2` and violate the documented
  caller contract (the exact class of slip A0-1(d) exists to catch on the apply
  side, with no counterpart on the cleanup side).
- **Historical dispositions retain superseded phrasing** — the Round-2 W2 entry
  still says "the fresh chain sits `:blocked`" (round-3 S2 corrected this to
  computed-position wording in the plan body). Acceptable as a historical
  record; noted only so nobody "fixes" the plan body back into agreement with
  the old disposition text.

## Disposition faithfulness — checked entry by entry

All round-3 findings are accounted for: the consolidated review's 5 warnings
(force-back premise, `create_atomics`, `discard/1` idempotency, A1-3↔A1-1c
coupling, M-12 disposition), 5 suggestions (A0-3 full-miss arming, `:blocked`
wording, `validate_action/3` + router, R-10 deletion, R-9 clearing semantics),
and 3 nits (moduledoc location, `apply_result` clause count, duplicated
`kick_next`) — plus pass 4's W1/S1/S2 and review-3's warning (broad force-back
would push `NotLoaded`/untouched-nil into updates — correctly recorded as moot
after the drop, with the tightened wording preserved for any future targeted
force-back) and suggestion (structured cleanup error — now in A1-1 with cause +
chain identity). The overturn of round-2 W1 is recorded in **both** the round-2
and round-3 disposition sections, so the history reads correctly from either
direction. The Facts section was amended in place with the round-3 corrections
(write_through spec location, the double-evaluation correction, the new round-3
bullet) and each checked against what round 3 actually verified.

## Summary

0 critical, 0 warning, 2 suggestions, 3 nits — all wording-level. Every
substantive round-3 finding was folded in accurately, the one cross-review
conflict was adjudicated the right way by source, and the newly-introduced
claims all verify. Nothing in this round touches the fix designs themselves:
A1-1 (capture → apply → transactional drop-by-ID → kick, with idempotent
`discard/1` as recovery), A1-2 (targets-first reorder, materialize-once via
`apply_attributes`, no force-back, both-fields atomics guard), A3 (`on_evict/3`
batch destroy-invalidation), and the B-side security fixes are stable across two
consecutive review rounds. Apply S1/S2 and the nits during implementation; no
further pre-implementation review round is warranted — the next thing this plan
needs is Phase A0.
