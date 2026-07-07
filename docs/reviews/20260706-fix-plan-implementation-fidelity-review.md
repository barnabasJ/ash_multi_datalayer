# Review: implementation fidelity against the 2026-07-06 fix plan

**Date**: 2026-07-06 **Input**: `docs/plans/20260706-review-findings-fix-plan.md`
(converged after 4 rounds / 10 passes, verdict "Ship it"), checked against what
actually landed — commits `fbc6d6a` (A0) through `599dc6c` (A4), plus the
uncommitted working-tree diff. **Scope**: Workstream A only (this repo); A5 is
out of scope by the plan's own decision and nothing from it leaked in.
**Verdict**: **one confirmed gap, otherwise faithful.** The prior ten passes
reviewed the plan's design before any code existed; that design was sound and
this pass found nothing wrong with it. What this pass checks instead — because
the design work is done and the code is already merged — is whether the
shipped code actually did what the plan's text specifically committed to. On
one named deliverable it did not, and the gap reproduces the exact failure mode
the plan set out to close. Everything else checked (A1-2 write_through
reordering/materialization/fields-guard, A1-3 co-commit validation, A1-4
discard_local/boot_hydrate, A2 flush taxonomy, A3 reconcile epoch protocol,
A4-1/2/4/5 hygiene, all 8 A0 harness scenarios but one sub-assertion, the full
test suite, and the uncommitted doc-only diff) matches the plan precisely.
Claims below were re-verified directly against source, not taken from the
audit that first surfaced them.

---

## Finding 1 (confirmed, should block calling A1 done): `discard/1` was never made idempotent

**What the plan required.** Phase A1-1 (`docs/plans/20260706-review-findings-fix-plan.md:179-184`):

> The recovery path is `discard/1` on the parked head — which is **not
> idempotent today** (round 3 W3: a second call, or one racing a flush, raises
> on the already-destroyed record); make `discard/1` idempotent as part of A1
> (not-found/stale on the destroy → treat as already discarded), and cover the
> **double-discard** in the cleanup-failure unit test.

This is not incidental phrasing — it is a named, load-bearing A1 deliverable,
and the Review disposition records it as a deliberate mid-review correction
(round 3 W3, `docs/plans/20260706-review-findings-fix-plan.md:684-691`):
pass 4 originally claimed `discard/1` was already idempotent, a second
reviewer at pass 5 re-checked and withdrew that claim, and the plan was amended
specifically to make idempotency an explicit A1 requirement rather than an
assumed pre-existing property.

**What shipped.** `lib/ash_multi_datalayer/orchestrator/local_outbox/api.ex:127-143`:

```elixir
def discard(entry) do
  outbox = entry.__struct__

  if entry.op == :create do
    chain = record_chain(entry)
    Enum.each(chain, &Ash.destroy!(&1, action: :discard, domain: domain(outbox), authorize?: false))
    {:ok, %{discarded: length(chain), dropped_chain: true}}
  else
    Ash.destroy!(entry, action: :discard, domain: domain(outbox), authorize?: false)
    {:ok, %{discarded: 1, dropped_chain: false}}
  end
end
```

No `rescue`, no not-found/stale handling, no idempotency wrapper. This is
byte-for-byte the pre-fix bug the plan's own Facts section describes
(`docs/plans/20260706-review-findings-fix-plan.md:565-567`): the non-`:create`
branch calls `Ash.destroy!` directly on the passed struct, so a second call —
or one racing a flush — raises. `git show effe382 --stat` (the A1 commit)
confirms `discard/1`'s body was never touched by A1: the diff covers
`local_outbox.ex`, `api.ex`'s `host/1`/`rebase/2`/`discard_local/1`/
`kick_next`, `conflict_error.ex`, `host_resolver.ex`, and `rebase_cleanup_error.ex`,
but not the `discard/1` function itself.

**This is live, not theoretical.** `discard/1` is the documented recovery verb
in two places that both assume it's safe to call under exactly the conditions
the plan worried about:

1. The runbook (`docs/runbooks/ash-multi-datalayer.md:202`, and the park-class
   table around line 218) tells operators to run `LocalOutbox.discard(entry)`
   to resolve a parked entry.
2. `RebaseCleanupError`'s own message
   (`lib/ash_multi_datalayer/orchestrator/local_outbox/rebase_cleanup_error.ex:25`)
   literally says *"resolve it via discard/1 (or retry/1, once the cause is
   fixed)"* — this is the error A1-1 introduced for exactly the rebase-cleanup-
   failure scenario, and its own suggested fix is the one verb the plan flagged
   as unsafe to call twice.

So: an operator who hits a `RebaseCleanupError`, follows the error's own
advice, and either double-clicks `discard/1` or has a flush race in behind
their manual call, gets a raise instead of the idempotent "already discarded"
result the plan specified. That is the identical shape of bug M-1 was opened
to close — un-handled failure on a resolution path — just moved one function
over.

**Compounding gap: no regression test exists either.** The plan bundled the
test with the fix ("cover the double-discard in the cleanup-failure unit
test"). Confirmed absent: `grep -rn "RebaseCleanupError\|discard" test/` finds
no test exercising a second `discard/1` call or a discard racing a flush.
`test/integration/local_outbox_resolution_test.exs` covers rebase's cleanup-
transaction happy path and the M-5 `discard_local` failure case, but not this.
So there's no gate that would have caught the fix being dropped, and none that
will catch a regression later.

**Why this got through a 4-round, 10-pass review process and a green suite**:
the plan's own Phase A1 gate text (`docs/plans/20260706-review-findings-fix-plan.md:243-245`)
lists "Phase A0 tests 1, 2, 5, 6 green; A0-7 ... A0-8 ... full suite green" —
it does not separately name the double-discard test as a gate item the way it
names the other A0 tests by number, even though the A1-1 body text commits to
building it. The gate as literally written could pass (and did) with this
requirement silently unmet. That's a real hole in the plan's own
self-checking, not just an implementation slip: a deliverable stated in prose
but never promoted into the itemized gate list is exactly the kind of thing
that survives to "done."

**Do not patch this in isolation.** This exact gap is already tracked, at
larger scope, by the second whole-repo review: `discard/1`'s non-idempotency
and missing next-entry-kick is finding
[#16](../reviews/20260706-second-review-findings.md#L245) and the general
"resolution verbs have no state guards and are non-idempotent" problem
(retry/force/discard/rebase, not just discard) is finding
[#17](../reviews/20260706-second-review-findings.md#L256), both scoped into
`docs/plans/20260706-second-review-findings-fix-plan.md` Phase A5, item 8:
*"Add resolution verb state guards: only parked chain heads may be retried,
forced, discarded, or rebased. Re-fetch before applying; convert not-found or
stale destroy into idempotent `:ok` where the desired final state is already
true."* That plan has not been implemented yet and is out of scope here — no
ad hoc fix should land outside its process. The value of restating the gap in
this review is narrower: it confirms, independently and from the
implementation side, that A5/#16/#17 are real and still open — this is not a
theoretical finding invented by the second review, it's the same named A1
deliverable from the first plan that never shipped, now independently
corroborated.

---

## Two informational deviations (no action needed)

**Rescue location, textually not where the plan says.** A1-1's text
(`docs/plans/20260706-review-findings-fix-plan.md:174-176`) says *"`rebase/2`
must rescue at its boundary and wrap the raise into that structured error."*
In the shipped code the `rescue` actually lives on the private helper
`destroy_captured_chain/3` (`api.ex:258-282`), not textually inside `rebase/2`
(`api.ex:226-245`) — `rebase/2` calls `destroy_captured_chain`, which already
converts any raise to `{:error, %RebaseCleanupError{}}` before `rebase/2`'s own
`case` ever sees it. The externally observable contract (no raise escapes
`rebase/2`) is exactly what the plan requires; the discrepancy is purely about
which function's body contains the literal `rescue` keyword. Not a bug — noting
it only because Finding 1 shows this exact area (rebase cleanup and its
recovery path) is where a real gap actually lived, so it's worth having
checked precisely.

**A4-3 (known-resource-map resolution) and A4-6 (write_through moduledoc
promotion) shipped in the A1 commit, not A4.** Both fully match their spec —
`host_resolver.ex` backs both `flush.ex`'s and `api.ex`'s resource resolution,
and `write.ex`'s moduledoc states the targets-first order as documented
behavior. They simply landed a phase earlier than the plan's phase numbering
assigns them. Since the plan's suggested landing order allows "A1+A2 together"
as one PR and doesn't forbid pulling work earlier, this is not a process
violation — flagged only so the A4 commit message's stated scope doesn't
mislead anyone reading `git log` cold.

---

## Everything else: verified matching, no note needed

Re-verified directly against source (not just re-stating the plan): A1-2's
`drain_chain_inline → materialize → push_all_targets → local_write` ordering,
`apply_attributes/1` materialization with both return shapes handled, the
`:fields` push option (PK ∪ changed ∪ loaded, `%Ash.NotLoaded{}` excluded), the
atomics guard on both `changeset.atomics` and `changeset.create_atomics`, and
the nil-create-PK guard (`write.ex:51-193`); A1-3's compile-time co-commit
rejection plus the runtime rescue-to-`{:error,_}` belt-and-suspenders
(`local_outbox.ex:193-218`, `write.ex:307-311`); A1-4's `discard_local/1`
error-propagation and `boot_hydrate/1`'s warn-then-`:ok` (`api.ex:154-177`,
`422-445`); A2's `classify/1` `:auth` head, `apply_result/6`'s immediate-park
branch, the `error_class` constraint's `:auth` addition
(`inject_outbox.ex:84`), and `ConflictError` replacing the bare tuple; A3's
`Invalidation.on_evict/3` doing one ledger scan across all ghosts and one epoch
bump per reconcile batch, shared with `on_write`'s `should_drop?`/
`evict_physical_row`; A4's `transaction/4` rollback-throw catch, the
`ExternalChange` exit/throw catch alongside its existing rescue, and the
M-7/M-8 doc notes both in-code and in the technical doc. `mix test` (118
passed) and `INTEGRATION=1 mix test` (266 passed) are both green with no
failures. The uncommitted working-tree diff (`backfill.ex`,
`coverage/invalidation.ex`, `orchestrator.ex`, `local_outbox/write.ex`,
`remote_context.ex`, `sync/enqueue.ex`, `telemetry.ex`, `CHANGELOG.md`, and
several docs) is prose/moduledoc/line-wrap only — no logic or signature
changes, and nothing in it touches or papers over Finding 1.

## Bottom line

The plan's design work holds up; nothing found here reopens any of the prior
rounds' decisions. The one real problem is narrow and well-scoped: `discard/1`
non-idempotency, a named A1 deliverable, did not ship, its own error message
tells operators to rely on it anyway, and no test exists to catch the gap.
Treat Phase A1 as not-fully-done on this one point, but the fix itself is
already someone else's scoped work: it's findings #16/#17 in
`docs/plans/20260706-second-review-findings-fix-plan.md` Phase A5. Nothing here
should be implemented ahead of that plan.
