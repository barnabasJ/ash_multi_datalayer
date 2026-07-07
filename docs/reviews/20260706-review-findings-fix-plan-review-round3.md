# Review (round 3): 2026-07-06 review-findings fix plan

**Date**: 2026-07-06 **Scope**:
`docs/plans/20260706-review-findings-fix-plan.md` (the twice-amended plan, after
review rounds 1–2). Method: every load-bearing claim in the plan was re-verified
against source — `ash_multi_datalayer` `lib/` + `test/support/`, sibling
`../ash_remote`, and the vendored Ash (`deps/ash`, 3.29.3) for the
framework-semantics claims the round-2 amendment leans on. The prior four review
passes were read; nothing below repeats an already-dispositioned finding.
Uncommitted working-tree changes in `lib/` were checked and are doc-only — they
do not invalidate the plan's Facts section.

## Verdict

**No criticals. The plan remains implementation-ready**, with point amendments.
The most important finding (W1) corrects a premise that round 2 introduced: the
"lazy defaults evaluated twice" hole that motivated A1-2's force-back step does
not exist on the standard action pipelines, so the step is defense-in-depth, not
a bug fix — and the A0-2 test the plan designates as its gate cannot fail for
that reason, which breaks the plan's own repro-first discipline as written. The
remaining findings are spec-precision fixes (a wrong idempotency claim, a wrong
atomics field, an unstated dependency between A1-3 and A1-1c, and a missing
disposition for M-12).

## Findings

### W1 [warning] A1-2's double-evaluation premise is moot on the standard pipeline; A0-2 cannot gate it (plan lines 136–152, 434–438, and the round-2 W1 disposition)

The round-2 amendment rewrote A1-2 around this chain: `apply_attributes`
materializes lazy defaults on a copy → the local data layer calls
`apply_attributes` again at commit → lazy defaults (`&Ash.UUID.generate/0`,
`&DateTime.utc_now/0`) are evaluated twice → target and local rows diverge in
PK/timestamps. The middle links are real (verified: ETS re-applies at
`deps/ash/lib/ash/data_layer/ets/ets.ex:1700`), but the chain never fires on the
paths `write_through` is reachable from, because **Ash materializes lazy
defaults into `changeset.attributes` before the data layer runs**:

- Create: `Ash.Changeset.set_defaults(:create, true)` at
  `deps/ash/lib/ash/actions/create/create.ex:277`.
- Update: same, `deps/ash/lib/ash/actions/update/update.ex:510` and `:551` (and
  bulk-update at `actions/update/bulk.ex:2781`).
- `set_lazy_defaults` writes the evaluated values in via
  `force_change_attribute` (`changeset.ex:4146`, `:4181`), and every later
  `set_defaults(..., true)` — including the one inside `apply_attributes`
  (`changeset.ex:7566-7568`) and the ETS layer's own re-apply — is guarded by
  `changing_attribute?` (`changeset.ex:4142`, `:4177`) and will **not**
  re-evaluate an attribute that is already present.

So by the time MDL's `write_through/3` sees the changeset, PK and timestamps are
concrete values; `apply_attributes` for the target push and the local layer's
re-apply both read the same values. MDL exposes only single-record
`create`/`update`/`destroy` callbacks (`data_layer.ex:579-591`), all invoked
below those pipelines.

Consequences for the plan:

1. The force-back step ("force the materialized values back into the changeset")
   is **redundant on every reachable path**, though harmless. It remains a
   reasonable belt for changesets that somehow bypass `set_defaults(..., true)`
   (note: `for_create` alone runs only the _static_ variant,
   `changeset.ex:3181`; and the bulk-create module has no lazy `set_defaults`
   call of its own — if a bulk-create fallback path ever reaches
   `write_through`, the belt earns its keep). Keep it if you want, but as
   _documented hardening_, not as the fix for a demonstrated hole.
2. **A0-2's "gate for the double-evaluation hole" claim is unsound** (plan lines
   150–152): a lazy-defaulted attribute driven through a normal `Ash.create`
   arrives pre-materialized, so the field-for-field test fails only for M-2's
   ordering reason, before and after the force-back. There is no test that
   "failed before" the force-back sub-fix — the plan's own repro-first rule
   (line 20–21) cannot be satisfied for it as specified. Reword A0-2 to gate
   what it actually gates (the M-2 reorder + shared materialization), and mark
   the force-back as untestable-by-design hardening or construct its repro
   explicitly (a hand-built changeset that skips `set_defaults(..., true)`).
3. The Facts-section sentence "the double-lazy-default-evaluation hole A1-2's
   force-back closes" (lines 434–438) and the round-2 W1 disposition line
   ("verified the ETS layer's create path re-applies") should be corrected: the
   re-apply is real, the _hole_ is not — the round-2 verification checked the
   callee but not the caller's pipeline, which had already closed it.

### W2 [warning] The atomics guard checks the wrong field for creates (plan line 143)

A1-2 says "reject a `write_through` changeset that carries atomics". On create
actions, atomics never populate `changeset.atomics` — they live in
`changeset.create_atomics` (`deps/ash/lib/ash/changeset/changeset.ex:1481`,
`:1509`; the ETS layer consumes exactly that field, `ets.ex:1710-1711`). A guard
on `changeset.atomics != []` silently passes every create-time atomic — the
exact op type where the plan's `apply_attributes` materialization is blind to
them (pass 3 S2's point). Specify the guard as
`changeset.atomics != [] or changeset.create_atomics != []`.

### W3 [warning] The A1-1 recovery path claims `discard/1` is idempotent — it isn't (plan line 125)

`Api.discard/1` (`orchestrator/local_outbox/api.ex:118-134`) runs
`Ash.destroy!(entry, action: :discard, ...)` on an entry **record** — a second
call, or a call racing a flush that already discarded the head, raises rather
than no-oping. The plan's parenthetical "(destroy-by-ID is idempotent)" is false
today, and the cleanup-failure recovery path leans on it. Either (a) make
`discard/1` idempotent as part of A1 (rescue/mátch the not-found error → `:ok`)
— the better fix, since the recovery runbook will tell an operator to call it,
possibly twice — or (b) drop the parenthetical and let the recovery path
tolerate a raise. Whichever way, the A1-1 cleanup-failure unit test should cover
the double-discard.

### W4 [warning] A1-1c's transaction exists only when the outbox layer has a repo — the plan doesn't state the dependency on A1-3 (plan lines 119–121, 156–158)

The only transaction machinery in scope is `write.ex`'s `in_transaction/2` +
`co_commit_repo`/`repo_of` (`write.ex:206-236`): `in_transaction(nil, fun)` runs
`fun.()` **bare**, and `repo_of` resolves a repo only for SQL-backed layers. So
"destroy exactly the captured entries inside one outbox-repo transaction,
all-or-nothing" silently degrades to non-atomic destroys for a repo-less outbox.
A1-3's chosen posture (reject configs whose co-commit repo is unresolvable)
makes that configuration unrepresentable — but A1-3 itself keeps an "if kept for
tests" escape hatch (line 157), and the A1-1 cleanup-failure unit test must then
run against a SQL outbox or it exercises the non-transactional path. State the
coupling in A1-1c ("transactional cleanup presumes A1-3's repo requirement; for
any repo-less path that survives, destroy the captured entries
parked-head-**last** so a partial failure leaves the evidence and the blocker
intact — same posture, no transaction").

### W5 [warning] M-12 has no disposition; half its items are uncovered

The plan's input review ends with two test-gap findings. R-11's five items are
all covered by Phase B0. M-12 lists eight; A0 covers four (rebase, write_through
failure local-state, `classify/1` taxonomy, `discard_local` failure) and the
plan never mentions M-12, unlike M-10/M-11 which get explicit out-of-scope
declarations. Uncovered: **boot hydration** (`:on_start`/`:if_empty`) —
especially pointed since A1-4 _changes_ `boot_hydrate`'s failure behavior with
no test named anywhere; **`Flush.chain_position` `:blocked` path** — which
A1-1's whole failure posture now leans on (the fresh chain "sits blocked");
**`SqlPassthrough` error branches**; **`RemoteContext` threading into flush
pushes**. Give M-12 a disposition: fold the first two into A0/A1 gates (they are
cheap and load-bearing for this plan's own fixes), and declare the last two
follow-ups if that's the intent.

### S1 [suggestion] A0-3's park must be reached via the full-miss path — the harness has no "park in reconcile" selector (plan lines 77–88)

`BlockingLayer.arm/1` parks the **next** `run_query` on the wrapped module
(`test/support/blocking_layer.ex`), and it distinguishes layers, not call sites.
On the full-miss/`source_read` path the reconcile scan
(`proven_coverage.ex:797`) is the first cache-layer `run_query` after arming —
arm there and the park lands where the plan wants it. On the remainder path,
`remainder_read`'s cache-half read (`proven_coverage.ex:549`) fires first and
would take the park. A0-3 should say "drive a full miss (empty ledger for the
query) and arm the wrapped cache layer before the read" — one sentence that
saves the implementer from a test that parks in the wrong place and silently
passes pre-fix again (the exact failure mode pass 2 C2 caught).

### S2 [suggestion] "`:blocked`" is a computed chain position, not a persisted state (plan lines 111–112, 122–124)

The stored state machine is `one_of: [:pending, :parked, :synced]`
(`inject_outbox.ex:70-80`); `:blocked` is what `Flush.chain_position/3` returns
at flush time when a lower-`seq` ancestor is parked (`flush.ex:57-75`). A1-1's
"the new entries enqueue `:blocked`" reads as a state write. Reword ("enqueue
`:pending` and are held `:blocked` behind the parked head at flush time") so the
A0/A1 tests assert the right thing — flush behavior or `chain_position`, not a
`state` field value that will never be `:blocked`.

### S3 [suggestion] The validate path needs an arity change the plan doesn't name (plan lines 274–281, 297–305, 322–326)

`Server.validate_action/2` takes `(otp_app, params)` — no opts at all — and the
router invokes it **without** `ash_remote_request_opts`
(`server/router.ex:49-54`), so today the validate path has neither actor nor
conn tenant. B1-1 ("`validate_action` uses the wire tenant, falling back to the
conn tenant") and B1-4 ("thread the actor into `validate_action`'s subject")
jointly require `validate_action/3` plus the router call-site change. Name that
in B1 so the two sub-items don't each half-fix the signature, and have B0-1's
validate-path test assert actor and tenant together.

### S4 [suggestion] B3-2's "decide by checking what Gen emits" — the check is done; record the answer (plan lines 360–364)

`Gen`'s generated `remote do` block emits only `source`, `schema_version`,
`base_url`, and optional `realtime?` (`gen/generator.ex:255-267`) — no per-field
operator info — while the loader _does_ normalize `filter_operators`
(`loader.ex:184-193`) and `encode/filter.ex:11-12` already documents the gate as
unwired. So the R-10 decision is: either extend the generator to emit per-field
operators _and_ wire loader → `remote_config` → encoder, or delete the
`:applicable` parameter and its dead gate. Given nothing consumes it and the
manifest data survives in the loader for a future re-introduction, deletion is
the smaller, honest change — but either way the plan can commit now instead of
deferring a decision whose input it already has.

### S5 [suggestion] R-9's "connect_params change clears the set" can't be observed in-process (plan lines 346–351)

`Connection` evaluates `connect_params` once in `init/1` and reuses
`socket.assigns.join_params` on every reconnect (`realtime/connection.ex:33`,
`:53-61`) — a fresh token is only picked up by a **new** socket process, whose
state (including the planned denied-topics set) starts empty anyway. As written,
the "clears the set" requirement is either automatic (new process) or impossible
(same process never sees new params). Reword to "the denied set is process state
and resets with the socket", or — if same-process token refresh is actually
wanted — add "re-evaluate `connect_params` on each reconnect and clear the set
when they change" as an explicit behavior change with its own test.

### Nits

- Plan line 39 and 405 say `write_through`'s **moduledoc** is the targets-first
  spec; the spec actually lives in the inline comment above `write_through?/1`
  (`write.ex:33-37`) — the module's moduledoc describes the async path. A4's
  docs sweep should promote it to the moduledoc it's claimed to be.
- Plan line 183–185: "`apply_result/6` branches only on
  `:rejected`/`:transient`" — true of its `{:error, _}` clause; the function
  also has `:ok` and `{:conflict, _}` clauses (`flush.ex:82-104`). The planned
  "new third clause" is a third _classify branch_ inside the error clause.
  Harmless, but an implementer grepping for a two-clause function will stumble.
- `flush.ex` and `api.ex` each independently implement `kick_next` and the
  `:for_record` chain read; A1-1 touches chain semantics in `api.ex` only. Worth
  one line in A1: change both or extract, or the two copies drift.

## Verified — the plan's load-bearing claims that hold

Everything below was checked against source and is **correct as stated** in the
plan; no action needed. Listed so the next round doesn't re-litigate:

- **M-1**: `rebase/2` is apply-then-`drop_chain` (`api.ex:183-193`);
  `drop_chain` → `record_chain` selects by
  `(resource, record_pk, target, state != :synced)` and provably cannot
  distinguish the fresh entries the apply just enqueued (`:pending`) from the
  old chain — ID capture is load-bearing exactly as the plan argues. Entry PK is
  `seq`; `kick_next` exists.
- **M-5**: `discard_local/1` ignores both `Backfill` results and drops the chain
  unconditionally (`api.ex:137-153`).
- **M-2**: runtime order is
  `drain_chain_inline → local_write → push_all_targets` with the pushed record
  taken from `local_write`'s return (`write.ex:42-52`);
  `Target.record_from_entry` indeed needs a persisted entry and doesn't fit.
- **M-6/A2**: `classify/1` has exactly the five claimed heads with no forbidden
  head (`flush.ex:203-207`); the `error_class` constraint is
  `one_of: [:transient_exhausted, :rejected, :conflict]`, transformer-injected
  (`inject_outbox.ex:81-86`); the generator emits no `error_class` — the
  "upgrade + recompile, no migration" note is exactly right. `retry/1` exists
  (parked → pending → re-flush). The conflict halt is the untyped
  `{:error, {:conflict, remote}}` tuple (`write.ex:63-80`); no `ConflictError`
  exists yet.
- **M-4**: `co_commit_repo` → `nil` for ETS-local + SQLite-outbox,
  `in_transaction(nil, _)` runs bare, and `enqueue_entries` uses `Ash.create!`
  (raises) — both halves of the finding confirmed.
- **M-3/A3**: `on_write/4` does bump + evict + drop and
  `should_drop?(entry, ghost, nil)` works destroy-style (`nil` new-row side is
  simply not matched) — the `on_evict/3` shape is directly buildable.
  `covers?/3` never consults the epoch. `maybe_backfill`'s `epoch_moved?`
  pre-check sits after the source fetch and before `reconcile`
  (`proven_coverage.ex:690-743`); today's `evict_ghost` is a bare
  `Backfill.destroy_record` with no epoch/ledger participation
  (`proven_coverage.ex:796-839`). `Coverage.record/5` is pre-check → insert →
  verify-or-drop, so the accepted "initiating read skips its own record"
  consequence plays out exactly as documented, surfacing as
  `:backfill_aborted / :epoch_moved_at_record`. `Coverage.entries/2` is a single
  `:ets.select` — the one-scan batch is real.
- **M-8 / A4-2**: `transaction/4`'s fallback is bare `{:ok, fun.()}` and the
  `rollback/2` fallback throws `{:rollback, term}` (`data_layer.ex:350-370`) —
  the throw escapes uncaught, and `ExternalChange.notify/1` has `rescue` only
  (`notifiers/external_change.ex:31-51`), so an exiting/throwing reaction still
  crashes the notifying socket.
- **A4-3**: the two unguarded `String.to_existing_atom(entry.resource)` sites
  are `flush.ex:38` and `api.ex:429`. No known-resource registry exists yet;
  `Supervisor`'s domain walk (`supervisor.ex:59-73`) is the natural source for
  building one.
- **R-1**: no tenant key anywhere in the protocol body; client never reads
  `query.tenant`/`changeset.to_tenant` on any wire path; server tenant comes
  only from the conn (`router.ex:76-83`) — the fallback the plan wants already
  exists. **R-2**: both `resolve_resource` sites mint via `Module.concat`
  pre-check; the channel's `rescue ArgumentError` is dead code; the two sites
  check different sets (RPC: `resources/1`; channel: `publications/1`-derived).
  **R-3**: `payload/4` serializes `Decoder.write_fields` (all public attrs, no
  actor) and `changed/2` builds its own map from `public_attributes` — both
  paths leak, as the plan's "strip both" requires. **R-5**: `safe_message/1`
  returns `Exception.message` for everything. **R-6**: raw
  `{:transport_error, _}`/`{:http_error, _, _}` tuples fall through the
  `{:error, other}` arm in all four call sites; only wire error _lists_ get
  `to_ash_error`. **R-7**: `upsert/3` is read-then-dispatch with no collision
  retry. **R-8**: `Loader.atom/1` is `String.to_atom`, and `load/2` accepts
  http(s) URLs. **R-9**: no denied-set, rejoin-all on every reconnect,
  `:join_denied` re-emitted each time. **ClientId**: base_url-keyed,
  unconditional `put` on `register/1`, and `Transport.Req.headers/1` sees only
  `base_url` — the round-1 W5 reversal was right.
- **B0 harness inputs**: no context-multitenant fixture and no transport stub
  exist yet (the transport-error test uses a real unreachable host), but
  `%Config{}` already supports a pluggable `:module` and the data layer honors
  it — B0-4's stub is cheap. The e2e backend (port 4747, `reset!/0`, actor
  injection) and the realtime/channel harnesses are in place for B0-1/B0-3.
- **Review disposition faithfulness**: the round-2 review's two warnings and two
  suggestions are all genuinely incorporated in the current text; both round-1
  criticals remain fixed. (W1 above is about a premise the round-2 _review
  itself_ introduced, not about a dropped finding.)

## Summary

0 critical, 5 warnings, 5 suggestions, 3 nits.

The plan's structural decisions all survived a from-scratch source check — every
"Facts" bullet held except the two corrected here (the `discard/1` idempotency
parenthetical, and the moduledoc-location nit). The warnings are point edits: W1
rewords A1-2/A0-2 around a hole that the action pipeline already closes (keep
the force-back as hardening if desired, but stop claiming a failing repro for
it), W2 is a one-line field fix (`create_atomics`), W3 either adds not-found
tolerance to `discard/1` or drops the idempotency claim, W4 states the A1-3 ↔
A1-1c coupling, and W5 gives M-12 the explicit disposition M-10/M-11 already
have. None require redesign; the plan is implementable as amended.
