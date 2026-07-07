# Plan: fix the 2026-07-06 whole-repo review findings

**Date**: 2026-07-06 (amended same day through **four review rounds, ten
independent passes** — see [Review disposition](#review-disposition) at the end.
Round 1's two criticals rewrote the M-1 and M-3 fix designs; round 2 found no
criticals and hardened the M-2 materialization, the rebase cleanup posture, and
the A2 migration note; round 3 — also 0 criticals, verdict implementation-ready
— **overturned round 2's force-back** (the double-evaluation premise is moot:
Ash pre-materializes lazy defaults), fixed the atomics guard field
(`create_atomics`), made `discard/1` idempotency an A1 deliverable, and gave
M-12 its disposition; round 4 — 0 criticals, verdict **converged, no further
pre-implementation review warranted** — added write_through's outbound field
filtering (never push `%Ash.NotLoaded{}`), the rebase rescue-and-wrap clause,
and the A0 gate exemptions for arbitration sub-assertions) **Input**:
[the whole-repo review](../reviews/20260706-whole-repo-review.md) (finding IDs
M-1…M-12 for ash_multi_datalayer, R-1…R-11 for ash_remote are referenced below),
plus the plan reviews (linked per round in the
[Review disposition](#review-disposition)). Docs findings from the same review
are already fixed; sensitive-info residuals were reviewed and accepted. This
plan is **code only**. **Repos**: this repo and the sibling `../ash_remote`. The
two workstreams run in parallel with exactly one semantic coupling (A2 ↔ B2-1,
the error taxonomy across the flush seam — see the landing order); within each,
phases are ordered by severity and dependency. Repro-first discipline throughout
(the house rule from the critical-bugs plan): every behavioral fix lands with a
test that failed before it. **Out of scope**: M-10 (module splits) and M-11's
performance items — noted as follow-ups, not blockers; the stacked-orchestrators
RFC remains exploratory. M-7 (hit-path phantom absence during updates) is
**doc-only by decision**, handled in Phase A4 — the review's documented floor.
**Follow-up filed** (accepted direction, not scheduled): per-record atomic
support via capability delegation to the authority layer — the
[atomic capability delegation RFC](../design/20260706-atomic-capability-delegation-rfc.md);
sequence it after Phase A5 so the delegation lands in the consolidated `can?`,
and note its interaction with A1-2's write_through atomics guard (the RFC keeps
the rejection).

## Invariants being restored

1. **A resolution verb converges local and remote** (M-1, M-5): after
   `rebase`/`discard_local` returns `:ok`, either both sides hold the resolved
   value or the caller got an error with the parked chain intact. Never
   "returned ok, silently diverged, evidence destroyed".
2. **`write_through` means durable-on-the-server-or-error** (M-2): its moduledoc
   is the spec. A failed write_through leaves the local layer untouched.
3. **Every cache mutation participates in the epoch protocol** (M-3):
   reconcile's ghost eviction is a cache write and must make concurrent
   `record`s abort, like every other mutation.
4. **No silent non-replication** (M-4, M-6): a locally-committed write either
   has an outbox entry or the caller got an error; a parked entry's
   `error_class` names the real failure class (auth ≠ flaky network).
5. **The server trusts nothing it didn't validate, and validates nothing it
   didn't scope** (R-1, R-2, R-3): tenant travels with every RPC, client strings
   never mint atoms, and realtime never delivers a field RPC would deny.

---

## Workstream A — ash_multi_datalayer

### Phase A0 — regression harness (tests 1–6 failing before fixes; 7–8 and the marked sub-assertions are gap-fill/arbitration)

Extend `test/integration/local_outbox_test.exs` (or add
`local_outbox_resolution_test.exs`) with:

1. **M-1 rebase**: park a conflict; `rebase(entry, changeset)`; assert (a) a
   `:pending` outbox entry exists for the resolved write immediately after
   `rebase` returns (before any flush runs), (b) after a flush the target holds
   the resolved value, (c) a subsequent `refresh(:all)` does NOT revert the
   local row, and (d) when the resolution changeset **fails/raises**, the parked
   entry is still parked and the local layer is unchanged (invariant 1's error
   half — review pass 1's critical). With the current code (a) fails
   deterministically when the Oban queue is paused — pause it in the test so the
   flush can't win the race and mask the bug.
2. **M-2 write_through failure**: stub a target that always fails; issue a
   `write_through: true` update; assert the action errors AND the local layer
   still holds the pre-write value (today it holds the new value — asserting
   local state is the missing half of the existing test); this half carries the
   gate. Plus two sub-assertions that are **arbitration/gap-fill, expected green
   pre-fix and must stay green post-fix** (round 4 S1: pre-fix the code pushes
   `local_write`'s return, so target-equals-local holds by construction — these
   _regression-protect_ the A1-2 reorder rather than gate it):
   - **materialization**: a `write_through` `:create` on a resource with
     **lazy-defaulted** uuid PK and timestamps — the record the target received
     equals the record the local layer holds (field-for-field on PK, defaults,
     timestamps). Its arbitration role (round 3/pass 4): if it ever fails on the
     default fields, a path reached write_through without pipeline
     pre-materialization, and only then does a targeted force-back earn its way
     in ("no double-evaluation hole exists on reachable paths" — see A1-2).
   - **partial-select update** (round 4, second reviewer): a `write_through`
     update driven from a **partially selected** record — the target push must
     contain only loaded/materialized fields plus the PK, never
     `%Ash.NotLoaded{}` values (fails post-reorder without A1-2's field
     filtering; pre-fix it passes because the pushed record is the local layer's
     fully-loaded return).
3. **M-3 reconcile race**: use the existing `blocking_layer` harness (built for
   the C3 races). **Block R1 inside reconcile's cache-layer scan, not at the
   source fetch** — `maybe_backfill` checks `epoch_moved?` at its top, so a
   reader blocked at the source fetch aborts at that guard and reconcile never
   runs (the test would pass with no fix applied — review pass 2 C2). The
   reachable window is after the epoch pre-check, during `reconcile_layer`'s
   `Delegate.run_on_layer` cache read: park there, then writer creates matching
   row `r` through the normal write path (epoch bumps, `r` propagates), a second
   reader records fresh coverage entry P including `r`, R1 resumes and
   reconciles. Assert `r` still exists in the cache layer AND a follow-up read
   hitting entry P returns `r`. Confirm it fails (row destroyed, P orphaned)
   before Phase A3. Harness note (round 3 S1): `BlockingLayer.arm/1` parks the
   **next `run_query` on the wrapped layer** — it selects by layer, not call
   site — so drive a **full miss** (empty ledger for the query) and arm the
   wrapped cache layer right before the read; on the full-miss path the
   reconcile scan is the first cache-layer `run_query` after arming. On the
   remainder path the cache-half read would take the park instead and the test
   would silently pass pre-fix.
4. **M-6 taxonomy**: unit tests on `Flush.classify/1` — `%Ash.Error.Forbidden{}`
   and `%{class: :forbidden}` must not be `:transient`; integration: a target
   returning Forbidden parks the entry immediately with `error_class: :auth` (no
   retry-budget burn).
5. **M-4 no-co-commit config**: a resource whose local layer is ETS and outbox
   is SQLite — `validate_opts` must reject (or the enqueue failure must surface
   as `{:error, _}`, per the A1 decision below).
6. **M-5**: `discard_local` where the local write fails (stub layer) — must
   return `{:error, _}` and leave the parked entry in place.
7. **M-12 boot hydration** (added in round 3 — A1-4 _changes_ `boot_hydrate`'s
   failure behavior, so it needs coverage): `hydrate: :on_start` seeds an empty
   local layer at supervisor boot; `:if_empty` skips a non-empty one; and a
   failing hydrate (stub target) logs a warning and still boots (asserting the
   A1-4 behavior — this sub-assertion goes green with A1-4, the happy paths are
   gap-filling and may pass today).
8. **M-12 `chain_position` `:blocked`** (added in round 3 — A1-1's failure
   posture leans on it): with a parked ancestor holding the chain, a flush of a
   later entry is held `:blocked` (snoozed), and resolving the head unblocks it.
   May pass today (gap-filling); it becomes the regression net for the A1-1
   recovery path.

Gate: tests 1–6 fail for the review's stated reasons — for A0-2 the
gate-carrying half is "action errors AND local unchanged"; its materialization
and partial-select sub-assertions, like tests 7–8, are gap-fill/arbitration
(expected green pre-fix, must stay green post-fix; the partial-select one turns
red only if A1-2 lands without field filtering). The rest of the suite is green.

### Phase A1 — LocalOutbox divergence fixes (M-1, M-2, M-4, M-5)

1. **M-1** (design corrected per review pass 1's critical — the original
   drop-before-apply violated invariant 1's error half): in `api.ex` `rebase/2`,
   **capture the parked chain's entry IDs first, then apply the changeset, then
   destroy exactly the captured entries, then kick the queue**. Sequence: (a)
   read `record_chain(entry)` and hold the entry IDs — ID capture is
   load-bearing, not defensive: the fresh entries the apply creates share
   `(resource, record_pk, target)` with the old chain, so a key-scoped
   `drop_chain/1` after the apply is exactly the current bug; only IDs
   distinguish old from new. (b) Apply the changeset — the new entries enqueue
   `:pending` and are **held `:blocked` at flush time** behind the still-parked
   head (round 3 S2: `:blocked` is what `Flush.chain_position/3` computes, not a
   persisted state — the stored machine is `:pending/:parked/:synced`; tests
   assert flush behavior or `chain_position`, never a `state` field value of
   `:blocked`). (c) Destroy the captured old entries only — concretely (pass 4
   S2): the `Ash.destroy!(entry, action: :discard, ...)` calls run inside
   `Ash.DataLayer.transaction(outbox, ...)`, so the cleanup is all-or-nothing.
   **This presumes A1-3's repo requirement** (round 3 W4): a repo-less outbox
   has no transaction (`in_transaction(nil, fun)` runs bare); if any repo-less
   path survives A1-3's escape hatch, destroy the captured entries
   **parked-head-last** so a partial failure leaves the evidence and the blocker
   intact — same posture, no transaction. The A1-1 cleanup-failure test must run
   against a SQL outbox or it exercises the non-transactional path. (d)
   `kick_next` so the now-unblocked fresh chain flushes — note `kick_next` and
   the `:for_record` chain read are independently implemented in both `flush.ex`
   and `api.ex` (round 3 nit): change both or extract, or the copies drift.
   Failure postures, both halves of invariant 1: if the **apply** raises or
   errors, stop at (b) — parked chain intact, caller holds the error. If the
   **cleanup** (c) fails, nothing was destroyed (transaction): the resolution is
   applied locally and its fresh entries exist but are held behind the
   still-parked head — no divergence and no lost evidence, just paused
   replication, visible in `parked/2`; return a **structured error** (round 3:
   not a bare atom) carrying the underlying cause plus the still-parked
   head/chain identity (resource, record_pk, target, head entry id) so an
   operator can run the recovery directly. Mechanically (round 4 nit):
   `Ash.destroy!` raising inside `Ash.DataLayer.transaction` rolls back and
   **re-raises**, so `rebase/2` must rescue at its boundary and wrap the raise
   into that structured error — otherwise the raise escapes and violates the
   documented caller contract (the cleanup-side counterpart of what A0-1(d)
   catches on the apply side). The recovery path is `discard/1` on the parked
   head — which is **not idempotent today** (round 3 W3: a second call, or one
   racing a flush, raises on the already-destroyed record); make `discard/1`
   idempotent as part of A1 (not-found/stale on the destroy → treat as already
   discarded), and cover the **double-discard** in the cleanup-failure unit
   test. Unit-test the cleanup failure with a test-only failing `:discard`
   (validation toggled via test context).
2. **M-2**: reorder `write_through/3` to match its moduledoc:
   `drain_chain_inline → push_all_targets → local_write`. The pushed record can
   no longer come from `local_write`'s return, and (review pass 2 W3)
   `Target.record_from_entry` does not fit — `write_through` creates no entry.
   Concrete materialization (corrected in round 3 — the round-2 "lazy defaults
   evaluated twice" premise is **moot**, so the force-back is **dropped**): call
   `Ash.Changeset.apply_attributes(changeset)` (arity-1/opts form; there is no
   form taking the data — it folds `changeset.attributes` over `changeset.data`
   after `set_defaults`), handle both returns (`{:ok, record}` |
   `{:error, changeset}` — it fails closed on an invalid changeset), and push
   that record to the targets **with only its loaded/materialized fields plus
   the primary key** (round 4, second reviewer): on an update from a partially
   selected record, `apply_attributes` overlays changes onto `changeset.data`,
   so untouched unselected fields remain `%Ash.NotLoaded{}` — and the push path
   (`Target.upsert` → `Backfill.upsert_record`) defaults to **all** resource
   attributes when no `:fields` option is given, which would write NotLoaded
   garbage to the target (or fail the push). Thread a `:fields` option (loaded
   attributes ∪ changed attributes ∪ PK, excluding anything `%Ash.NotLoaded{}`)
   through `Target.upsert`/`destroy` from `push_all_targets`; the A0-2
   partial-select sub-assertion is its regression. The local write then runs the
   **original changeset unchanged**. Both sides see identical values because the
   Ash action pipeline pre-materializes lazy defaults into
   `changeset.attributes` before the data layer runs
   (`set_defaults(:create|:update, true)` in create.ex/update.ex), and every
   later `set_defaults` — including the local layer's own re-apply — is
   idempotent via the `changing_attribute?` guard. No values are forced back:
   that also closes round-3's other concern (forcing `%Ash.NotLoaded{}` or
   untouched-nil fields into the changeset on updates would corrupt the local
   write). The A0-2 lazy-default test is the arbitration: if it ever fails, a
   path reached write_through without pipeline pre-materialization, and only
   then add a **targeted** force-back (changed attributes + Ash-level defaults
   only, never NotLoaded/nil-untouched fields). Guards: reject a `write_through`
   changeset that carries atomics — checking **both** `changeset.atomics` and
   `changeset.create_atomics` (round 3 W2: create-time atomics live only in
   `create_atomics`; a guard on `atomics` alone silently passes every
   create-time atomic, the exact op `apply_attributes` is blind to) — or whose
   `:create` PK is still `nil` after materialization (a genuinely DB-generated
   key): a loud error tuple naming the limitation. DB-generated fields (PK or
   otherwise) are unsupported for write_through creates — say so explicitly in
   the moduledoc, not just for PKs. Accepted width mismatch (pass 5 S1): the
   guard catches only the nil PK (the catastrophic case); a non-PK DB-generated
   field would silently diverge on that field and is covered by documentation
   only — detecting DB-generated vs Ash-default generically isn't cheap; a
   DSL-level guard can ride along with A5's consolidation if wanted. If the
   local write subsequently fails, return an error tuple (server is ahead by one
   write; the next inbound realtime push or refresh converges local — document
   this residual in the moduledoc, it is the benign direction).
3. **M-4**: decide in `validate_opts`: co-commit repo resolvable for (local
   layer, outbox resource) is **required** — reject the config at compile time
   with a clear message (preferred; an orchestrator whose durability story is
   "co-commit" should not silently degrade). Keep a runtime belt-and-suspenders:
   wrap enqueue in the no-repo path (if kept for tests) so failures return
   `{:error, _}` instead of raising.
4. **M-5**: `discard_local/1` pattern-matches the backfill result; on error,
   return `{:error, _}` without dropping the chain. `boot_hydrate` logs
   `Logger.warning` with resource + reason before returning `:ok` (mirror
   `ExternalChange`'s warn-then-swallow contract).

Gate: Phase A0 tests 1, 2, 5, 6 green; A0-7's warn-on-failure sub-assertion
green (A1-4); A0-8 green as the A1-1 recovery-path regression net; full suite
green.

### Phase A2 — flush error taxonomy (M-6)

1. `Flush.classify/1`: add `classify(%Ash.Error.Forbidden{})` and
   `%{class: :forbidden}` → `:auth`, a third class that **parks immediately**
   (no retries — a token does not un-expire by retrying) with
   `error_class: :auth`. `retry/1` on an `:auth`-parked entry re-flushes (the
   operator fixed credentials — this is the recovery path, test it). Two
   downstream edits are required for this to work at all (review pass 2 W2): (a)
   the `error_class` attribute constraint in
   `sync/transformers/inject_outbox.ex` is
   `one_of: [:transient_exhausted, :rejected, :conflict]` — add `:auth` or the
   park write is rejected. Migration note (corrected per review pass 3 W1): the
   constraint is **transformer-injected at compile time** — the generator emits
   only the `extensions:` line and the `outbox_entry` block, never this
   attribute — so existing apps pick up `:auth` on **library upgrade +
   recompile**; no `gen.outbox` re-run, no manual edit, no DB migration (`:atom`
   is stored as a string). Say exactly that in the CHANGELOG. (b)
   `apply_result/6` in `flush.ex` — precisely (round 3 nit): its `{:error, _}`
   clause branches only on `:rejected` / `:transient` (the function also has
   `:ok` and `{:conflict, _}` clauses); the immediate-park behavior is a new
   third _classify branch inside that error clause_, not in `classify`.
2. Wrap `drain_chain_inline`'s conflict halt in a structured error
   (`AshMultiDatalayer.Orchestrator.LocalOutbox.ConflictError` carrying the
   remote snapshot) so Ash callers see a typed error, not
   `{:error, {:conflict, remote}}`.
3. Update the runbook's LocalOutbox section (added 2026-07-06) with the `:auth`
   park class.

Gate: A0 test 4 green; taxonomy unit tests cover all classify heads.

### Phase A3 — reconcile joins the epoch protocol (M-3)

**Design corrected per review pass 2 C1 — an epoch bump alone does not fix
this.** The bump only aborts records in-flight between their own insert and
verify; it cannot retroactively remove reader R2's already-**committed** entry
P, and `covers?` never re-checks the epoch — so the missing-row cache hit
survives a bump-only fix. `Invalidation.on_write` does three things (bump,
evict, **drop every entry whose filter matches the changed row**), and the drop
is the load-bearing step here.

Fix: reconcile's ghost eviction reuses `on_write`'s machinery as a destroy-style
invalidation — `should_drop?(entry, ghost, nil)` drops the covering ledger
entries, the physical rows are evicted, and the epoch is bumped **once per
reconcile batch**. Batch the ledger scan too (review pass 3 S1): per-ghost
`on_write` calls would each scan the full ledger (O(ghosts × ledger)) — instead
collect the ghost rows, scan `Coverage.entries/2` **once**, and drop any entry
for which `should_drop?(entry, ghost, nil)` holds for _any_ ghost. Shape: a
small `Invalidation.on_evict/3` (resource, tenant, ghosts) that shares
`should_drop?`/`evict_physical_row` with `on_write` and hoists the bump.

Known accepted consequence (review pass 1 W3): the initiating read's own
`Coverage.record/5` will now see `:epoch_moved` and skip recording whenever its
reconcile evicted ghosts — intentional and conservative (that reader's fetch
predates its own eviction's ledger surgery). Document it at the reconcile site
and add an A3 gate assertion: after a ghost-evicting read, the **next**
identical read misses, refetches, records cleanly, and hits thereafter.

Gate: A0 test 3 green (including the follow-up-read assertion above); the C3/C4
race suites stay green (they are the regression net for epoch-protocol changes);
property suites green.

### Phase A4 — shell + notifier hygiene (M-8, M-11 subset)

1. **M-8**: `data_layer.ex` `transaction/4` fallback wraps `fun.()` in
   `try/catch` for `{:rollback, term}` → `{:error, term}`. Unit test through a
   layer without transaction callbacks.
2. `ExternalChange.notify/1`: `catch :exit, _` / `:throw` in addition to
   `rescue` (a `GenServer.call` timeout inside a reaction exits, not raises);
   same warn-and-drop contract. Test with a reaction that exits.
3. `flush.ex`/`api.ex`: guard `String.to_existing_atom(entry.resource)` —
   resolve against a **known-resource map** (the LocalOutbox resources
   registered for the otp_app), never `Module.concat`/atom-minting on a
   persisted string (review pass 1 S7 — same class as R-2); an unresolvable
   resource parks the entry as `:rejected` (a stale outbox row for a deleted
   resource should not burn retries).
4. `@spec`s on the `LocalOutbox.Api` public surface (matches the coverage
   modules' standard).
5. **M-7 (doc-only, by decision)**: document the evict-then-repropagate window
   at `coverage/invalidation.ex` `evict_physical_row` and in the technical doc's
   concurrency notes: a reader between eviction and `WriteDispatch` propagation
   can observe a covered hit missing a row that existed before and after the
   update (an absence anomaly, not staleness). Revisit upsert-in-place only if
   it shows up in practice.
6. Docs nit from round 3: the targets-first write_through spec lives in an
   inline comment above `write_through?/1`, not in the module's moduledoc (which
   describes the async path) — promote it to the moduledoc the plan (and M-2)
   treat it as.

Gate: full suite + credo green.

**M-12 disposition** (round 3 W5 — previously undispositioned): of its eight
test gaps, A0 covers rebase, write_through failure local-state, `classify/1`
taxonomy, and `discard_local` failure; round 3 folded **boot hydration** (A0-7)
and **`chain_position` `:blocked`** (A0-8) into the harness because A1-4 changes
the former's behavior and A1-1's recovery posture leans on the latter. The
remaining two — **`SqlPassthrough` error branches** and **`RemoteContext`
threading into flush pushes** — are declared follow-ups (out of scope for this
correctness pass, same status as M-10/M-11).

### Phase A5 — Phase 4a consolidation (M-9) — separate PR/arc

This was already planned debt; the review confirms it is the highest-value
structural cleanup. Scope (unchanged from the Phase 4a notes in code):

1. Strategy options move into `orchestrator {Mod, opts}`; `ValidateOrchestrator`
   rejects options foreign to the chosen strategy (ProvenCoverage opts on a
   LocalOutbox resource become compile errors, not silent no-ops).
2. Deprecate-but-forward the current top-level DSL options for one release (the
   guide's examples use them).
3. Consolidate `can?`: shell keeps only the true fallback; delete
   `default_can?`/`layers_can?` duplication; single `@foldable_aggregate_kinds`
   source of truth.
4. Document per-strategy kill-switch semantics in `AshMultiDatalayer.disable!/1`
   (LocalOutbox: reads already local; writes still enqueue — say so) — or add a
   LocalOutbox `disable!` behavior (pause queue) if a real semantic is wanted.
   Decide at implementation; the doc-only version is the floor.

Gate: suite green; guide/runbook/CHANGELOG updated for the DSL move.

## Workstream B — ash_remote

### Phase B0 — regression harness

1. **R-1**: e2e multitenant test — a context-multitenant resource in the test
   backend; client reads/writes with `tenant:`; assert server-side scoping
   (today: fails — tenant is nil server-side). Cover the **validate path too**
   (review pass 1 S6): `Protocol.build_validate` + `Server.validate_action` must
   carry/apply tenant independently of `/rpc/run` — and the validate test
   asserts **actor and tenant together** (round 3 S3), since B1-1 and B1-4
   jointly change the same signature.
2. **R-2**: unit test — `resolve_resource` with an unknown string must not grow
   `:erlang.system_info(:atom_count)` (measure before/after a batch of distinct
   strings).
3. **R-3**: realtime field-policy test — resource with a field policy;
   subscriber who can read the row but not the field; assert the pushed payload
   omits it (today: fails).
4. **R-6/R-7**: data-layer test with a transport stub returning
   `{:error, {:transport_error, :econnrefused}}` — assert the Ash caller
   receives an `Ash.Error` (typed); upsert collision test — two upserts race
   (stub the read to return nil for both), server has a unique PK — second
   create resolves to update, no duplicate.

Gate: all fail for the stated reasons; suite otherwise green.

### Phase B1 — security (R-1, R-2, R-3, R-4, R-5)

1. **R-1 tenant on the wire**: add optional `"tenant"` to the protocol body
   (`Protocol.build_run`/`build_validate`); client threads `query.tenant` /
   `changeset.to_tenant` in `run_query`/`write`/`destroy`/calc fetches; server
   (`Server.run_action`/`validate_action`) uses the wire tenant, falling back to
   the conn tenant. Signature note (round 3 S3): `validate_action/2` is
   `(otp_app, params)` — **no opts at all** — and the router invokes it without
   `ash_remote_request_opts`, so today the validate path has neither actor nor
   conn tenant; B1-1 (tenant) and B1-4 (actor) jointly require
   **`validate_action/3`** plus the router call-site change — make that one
   edit, not two half-fixes. Bump nothing on the wire: an absent key is the old
   behavior, so the protocol stays backward compatible. Document that the wire
   tenant is **input to Ash multitenancy, not an auth claim** — policies must
   still scope actors to tenants server-side (add this to the README
   Authorization section).
2. **R-2 atom exhaustion**: precompute string→module maps and make
   `resolve_resource` a lookup — but note (review pass 2 S1) the two sites check
   **different sets**: `server.ex` tests membership in `resources(otp_app)`,
   `server/channel.ex` in the published set derived from
   `publications(otp_app)`. Build one map **per site**, and the cache key must
   carry the site tag (round-2 suggestion) —
   `{AshRemote.Server, :resource_map, otp_app, :rpc | :channel}` — so one
   resolver can't overwrite or reuse the other's map. Cache in
   `:persistent_term` (bounded — one term per app+site, written once).
3. **R-3 field-policy strip**: in `Server.Notifier`, compute the set of **policy
   target fields** — the fields the field policies apply to, not fields
   referenced by policy _conditions_ (review pass 1 W4) — once per resource, and
   exclude them from **both** serialization paths: `payload/4`'s `"data"` AND
   `changed/2`'s `"changed"` (both reviews; `changed/2` builds its map
   independently, so stripping only `"data"` still leaks new values). Document
   in the realtime section: field-policied attributes never travel over
   realtime; load them via RPC. (Chosen over per-subscriber evaluation for cost;
   revisit only if a real consumer needs pushed policied fields.)
4. **R-4**: thread the actor into `validate_action`'s subject; add a
   `verify_exposed_resources_have_authorizers` verifier that **warns** (not
   errors — bare demos are legitimate) when an `expose`d resource has no
   authorizers; add the loud moduledoc note to `AshRemote.Rpc` and
   `Server.Router`.
5. **R-5**: `safe_message/1` returns `Exception.message/1` only for
   `Ash.Error.Invalid | Forbidden | NotFound | Query.NotFound` classes;
   everything else → `"internal error"` + `Logger.error` with the real exception
   server-side.

Gate: B0 tests 1–3 green; realtime authz + e2e suites green.

### Phase B2 — correctness (R-6, R-7, R-9)

1. **R-6**: add `AshRemote.Error.Transport` (an `Ash.Error.Unknown`-class error
   carrying `reason`/`status`); map `{:transport_error, _}` and
   `{:http_error, _, _}` through it in all three data-layer branches and in
   `fetch_remote_calculations`. This is what MDL's `Flush.classify/1` will see —
   coordinate with Workstream A2 (a Transport error must classify `:transient`,
   a Forbidden inside it `:auth`).
2. **R-7**: on create-collision (server unique-constraint/`Invalid` on the
   create leg of `upsert/3`), re-read and retry as update once; document the
   remaining read-modify-write window in the moduledoc (true fix is a
   server-side identity upsert — file as a follow-up against the protocol).
3. **R-9**: `Connection` tracks topics denied with a terminal reason in state;
   `handle_connect` excludes them from rejoin. Clearing semantics corrected
   (round 3 S5, verified): `connect_params` is evaluated **once in `init/1`**
   and `join_params` is reused on every reconnect — within one socket process,
   params never refresh, so "clear on connect_params change" is unobservable
   in-process. The denied set is **process state and resets with the socket**; a
   fresh token arrives only via a new socket process, whose set starts empty
   anyway. (Also fix the misleading "evaluated per connect" comment at the
   `init/1` eval site while there.) If same-process token refresh is ever
   wanted, that's a separate behavior change (re-evaluate `connect_params` on
   each reconnect) with its own test — not part of this fix. Emit `:join_denied`
   once, not per reconnect. Test: denied topic + forced reconnect → exactly one
   `:join_denied` lifecycle event, no reconcile storm.

Gate: B0 test 4 green; full suite green.

### Phase B3 — hygiene (R-8, R-10)

1. **R-8**: `Manifest.Loader.atom/1` uses `String.to_existing_atom` with a
   rescue → clear error naming the offending manifest key (Ash vocabulary atoms
   all exist by load time); document that `load/2` must point at a trusted
   manifest.
2. **R-10**: decision made (round 3 S4 — the "check what `Gen` emits" input is
   in): the generated `remote do` block emits only
   `source`/`schema_version`/`base_url`/optional `realtime?` — no per-field
   operator info — so **delete the `:applicable` parameter and its dead gate**
   from `encode/filter.ex` (the smaller, honest change; the server remains the
   real gate, and the manifest data survives in the loader's normalized
   `filter_operators` for a future re-introduction that also extends the
   generator). **`ClientId` stays keyed by base_url** (decision reversed per
   review pass 1 W5: the HTTP request path — `Transport.Req.headers/1` — has
   only `base_url` in scope, no connection name or registry; re-keying would
   silently break echo suppression for RPC writes). Instead: (a) make
   `register/1` idempotent (`put` only when absent) so supervisor restarts stop
   triggering `:persistent_term` global GC scans, and (b) document that **one
   `AshRemote.Realtime` supervisor per base_url** is the supported topology —
   two named supervisors on one base_url share an echo-correlation identity by
   design; add a boot-time warning if a second registers a different id for an
   existing base_url.
3. `@spec`s on `Server.run_action/3`, `validate_action/3` (post-B1 arity),
   `entrypoints/1`, `manifest_json/1`, `DataLayer.remote_config/1`,
   `fetch_remote_calculations/3`.

Gate: suite + credo green.

## Final gate (both workstreams)

1. `mix test` green in both repos (MDL: including the `:integration` tagged
   set).
2. The example offline-first demo runs end-to-end per `example/README.md` in
   ash_remote (online invalidation, offline edit → conflict → resolve via each
   verb including `rebase`, refresh) — this is the only place M-1/M-2/R-1/R-6
   compose in one system. Follow the demo boot notes (ports, stale processes,
   deps.compile) from the previous session's runbook.
3. Docs sweep: moduledocs touched by semantic changes (write_through, classify,
   upsert, realtime field stripping), the guide's strategy section, the
   runbook's LocalOutbox section, both CHANGELOG/DECISIONS files.

## Suggested landing order

A0 → A1 → A2 → A3 → A4 (one PR each or A1+A2 together), then A5 as its own arc.
B0 → B1 → B2 → B3 in parallel with A. The only cross-repo coupling is A2/B2-1
(error taxonomy across the seam) — land B2-1 before or with A2, or have A2's
classify accept both the old tuple and the new Transport error during the
overlap.

## Facts (verified against source, 2026-07-06)

- `rebase/2` currently: apply changeset → `drop_chain(entry)` (api.ex); no test
  references `rebase(`.
- `write_through/3` currently:
  `drain_chain_inline → local_write → push_all_targets`; the targets-first spec
  lives in the inline comment above `write_through?/1` (round-3 correction: the
  module's moduledoc describes the async path — A4-6 promotes the spec).
- `Flush.classify/1` heads: `{:rejected,_}`, `{:transient,_}`,
  `%Ash.Error.Invalid{}`, `%{class: :invalid}`, catch-all `:transient` — no
  forbidden head.
- Both `resolve_resource` sites call `Module.concat([input])` before the
  membership check; the channel's `rescue ArgumentError` never fires
  (`Module.concat` doesn't raise).
- `Notifier.payload/4` serializes `Decoder.write_fields(resource)` (all public
  attributes) once, no actor in scope.
- `blocking_layer` test support exists from the C3 arc (reuse for A0-3).
- Both repos green pre-plan: MDL 115 passed / 132 excluded (integration tag),
  ash_remote 166 passed.
- (Added in amendment, verified against source) `Invalidation.on_write/4` does
  bump + evict + **drop** (`should_drop?` over all entries); `covers?/3` never
  consults the epoch; `maybe_backfill` checks `epoch_moved?` before calling
  `reconcile`; the outbox `error_class` constraint is
  `one_of: [:transient_exhausted, :rejected, :conflict]`; `apply_result/6`'s
  `{:error, _}` clause branches only on `:rejected`/`:transient` (the function
  also has `:ok` and `{:conflict, _}` clauses — round-4 S2 aligned this bullet
  with A2-1(b)); `Transport.Req.headers/1` receives only `base_url`-derived
  config; `drop_chain/1` queries by
  `(resource, record_pk, target, state != :synced)` — it cannot distinguish old
  entries from a rebase's fresh ones, hence the ID capture in A1-1.
- (Added in round-2 amendment, verified against source)
  `mix ash_multi_datalayer.gen.outbox` emits only the `extensions:` line and the
  `outbox_entry` block — the `error_class` attribute and its `one_of` constraint
  are injected at compile time by `sync/transformers/inject_outbox.ex`, so
  adding `:auth` propagates on recompile with no generator re-run and no
  migration. `Ash.Changeset.apply_attributes/1,2`
  (`apply_attributes(changeset, opts \\ [])`) runs `set_defaults` on a copy and
  returns `{:ok, record} | {:error, changeset}`; the ETS data layer calls
  `apply_attributes` again itself during create (ets.ex `create` path).
  **Round-3 correction to this bullet**: the re-apply is real but the
  "double-lazy-default-evaluation hole" is **not** — Ash's action pipelines call
  `set_defaults(:create|:update, true)` (create.ex / update.ex) before the data
  layer, `set_lazy_defaults` evaluates the default function once and
  `force_change_attribute`s the result in, and every later `set_defaults`
  (including inside `apply_attributes` and the local layer's re-apply) is
  guarded by `changing_attribute?` and does not re-evaluate. Round 2 verified
  the callee but not the caller's pipeline; A1-2's force-back was dropped
  accordingly.
- (Added in round-3 amendment, verified against source) Create-time atomics live
  in `changeset.create_atomics`, not `changeset.atomics` (the ETS layer consumes
  exactly that field) — A1-2's guard checks both. `Api.discard/1`'s non-create
  branch runs `Ash.destroy!` on the passed entry struct — a second call raises
  today (not idempotent; A1-1 fixes this). Realtime `Connection` evaluates
  `connect_params` once in `init/1` and reuses `join_params` on every reconnect
  (its "per connect" comment is misleading — B2-3 fixes it).
  `Server.validate_action/2` takes `(otp_app, params)` with no opts, and the
  router calls it without `ash_remote_request_opts` — the validate path today
  has neither actor nor conn tenant. `Gen`'s `remote do` block emits no
  per-field operator info — the R-10 `:applicable` deletion decision rests on
  this. The outbox stored state machine is
  `one_of: [:pending, :parked, :synced]`; `:blocked` is computed by
  `Flush.chain_position/3` at flush time, never persisted.

## Review disposition

Four review rounds, ten independent passes — round 1:
[pass 1](../reviews/20260706-review-findings-fix-plan-review.md),
[pass 2](../reviews/20260706-fix-plan-review.md); round 2 (on the amended plan):
[pass 3](../reviews/20260706-fix-plan-review-pass3.md),
[round-2 review](../reviews/20260706-review-findings-fix-plan-review-2.md);
round 3 (on the twice-amended plan):
[consolidated round-3 review](../reviews/20260706-review-findings-fix-plan-review-round3.md),
[pass 4](../reviews/20260706-fix-plan-review-pass4.md),
[round-3 review](../reviews/20260706-review-findings-fix-plan-review-3.md);
round 4 (on the thrice-amended plan):
[consolidated round-4 review](../reviews/20260706-review-findings-fix-plan-review-round4.md),
[round-4 review](../reviews/20260706-review-findings-fix-plan-review-4.md),
[pass 5](../reviews/20260706-fix-plan-review-pass5.md). Every claim below was
re-verified against source before adoption. Verdicts: every pass from round 2 on
— implementation-ready, 0 criticals; round 4: **converged, no further
pre-implementation review warranted** ("Ship it").

### Round 1

- **Pass 1 critical (M-1 drop-before-apply loses conflict evidence on raise)**:
  **accepted** — A1-1 rewritten to capture-IDs → apply → drop-captured-only →
  kick; A0-1 gained assertion (d).
- **Pass 2 C1 (epoch bump alone cannot drop committed covering entries)**:
  **accepted** — verified `covers?` has no epoch check and `on_write`'s entry
  drop is the load-bearing step; A3 rewritten to on_write-style destroy
  invalidation.
- **Pass 2 C2 (A0-3 would block before the `epoch_moved?` guard)**: **accepted**
  — verified the guard sits at the top of `maybe_backfill`; A0-3 reworded to
  park inside reconcile's cache-layer scan.
- **Pass 2 W1 (M-7 silently dropped)**: **accepted** — doc-only disposition now
  explicit in the header and Phase A4-5.
- **Pass 2 W2 (`:auth` blocked by the `error_class` constraint; `apply_result/6`
  needs a third clause)**: **accepted** — verified both; added to A2-1 (its
  migration note was then corrected again in round 2, see pass 3 W1 below).
- **Pass 1 W2 / Pass 2 W3 (write_through record materialization under-specified;
  changeset-derived records miss generated values)**: **accepted** — A1-2 now
  specifies `apply_attributes`, the nil-PK guard for creates, and A0-2 gained
  the field-for-field materialization test (further hardened in round 2).
- **Pass 1 W3 (initiating read skips its own record after eviction)**:
  **accepted** — documented as intentional in A3 with a follow-up-read gate
  assertion.
- **Pass 1 W4 / Pass 2 S3 (strip policy _target_ fields, from `"data"` AND
  `"changed"`)**: **accepted** — B1-3 amended.
- **Pass 1 W5 (ClientId re-keying breaks the HTTP path)**: **accepted** — B3-2
  decision reversed: keep base_url keying, idempotent register, documented
  topology + boot warning.
- **Pass 2 W4 (workstream independence overstated)**: **accepted** — intro
  reworded to name the A2 ↔ B2-1 coupling.
- **Pass 1 S6 (validate-path tenant test)**: **accepted** — B0-1.
- **Pass 1 S7 (LocalOutbox resolver must not mint atoms)**: **accepted** — A4-3
  uses a known-resource map.
- **Pass 2 S1 (the two resolve sites check different sets)**: **accepted** —
  B1-2 builds per-site maps.
- **Pass 2 S2 ("capture first" unnecessary)**: **superseded**, not adopted — it
  reviewed the now-replaced drop-before-apply design; under the corrected
  drop-after-by-ID design, capture is load-bearing (see the `drop_chain` fact
  above), which pass 1's critical requires.

### Round 2 (on the amended plan)

- **Pass 3 W1 (the `error_class` constraint is transformer-injected — "re-run
  `gen.outbox`" was wrong guidance)**: **accepted** — verified the generator
  emits only `extensions:` + the `outbox_entry` block; A2-1's migration note
  corrected to "library upgrade + recompile; no generator re-run, no manual
  edit, no DB migration".
- **Round-2 W1 (lazy defaults evaluated twice: `apply_attributes` materializes
  on a copy, and the local data layer calls `apply_attributes` again at
  commit)**: **accepted in round 2, then overturned in round 3** — the round-2
  verification confirmed the callee (ETS re-applies) but not the caller's
  pipeline, which pre-materializes lazy defaults idempotently; the force-back
  this introduced was dropped again (see Round 3 below). The lazy-defaulted test
  attribute survives as the arbitration gate.
- **Round-2 W2 (rebase cleanup failure after a successful apply had no defined
  posture)**: **accepted** — A1-1 step (c) now runs in one outbox-repo
  transaction; on cleanup failure nothing is destroyed, the fresh chain sits
  `:blocked` behind the intact parked head (no divergence, no lost evidence),
  the caller gets a distinct error naming the state, and `discard/1` on the
  parked head is the recovery path; unit test with a test-only failing
  `:discard`.
- **Pass 3 S1 (per-ghost drops scan the ledger N times)**: **accepted** — A3 now
  specifies one ledger scan matching any ghost (`Invalidation.on_evict/3`
  shape).
- **Pass 3 S2/S3 (atomics not covered by `apply_attributes`; handle its
  `{:error, changeset}` return; arity wording)**: **accepted** — A1-2 guards
  reject atomics-carrying write_through changesets, handle both return shapes,
  and name the arity-1/opts call form.
- **Round-2 S1 (single `:persistent_term` key can't serve two per-site maps)**:
  **accepted** — B1-2's cache key now carries the site tag.
- **Round-2 S2 (markdown typos in A1-2)**: **accepted** — cleaned up in the A1-2
  rewrite.

### Round 3 (on the twice-amended plan)

- **Round-3 W1 / Pass 4 W1 (the round-2 double-evaluation premise is moot: the
  Ash pipelines pre-materialize lazy defaults before the data layer, and
  `set_defaults` is idempotent via `changing_attribute?`)**: **accepted** —
  verified the guard in deps/ash; A1-2's force-back **dropped** (also resolving
  the round-3 review's warning that a broad force-back would push
  `NotLoaded`/untouched-nil values into update changesets); A0-2 reworded to
  gate the reorder + shared materialization, doubling as pass 4's arbitration
  test; the contradicting Facts bullet and the round-2 W1 disposition corrected
  in place.
- **Round-3 W2 (create-time atomics live in `create_atomics`, not `atomics`)**:
  **accepted** — verified the field; A1-2's guard checks both.
- **Round-3 W3 (`discard/1` is not idempotent — the plan's recovery
  parenthetical was false)**: **accepted, adjudicating a cross-pass conflict** —
  pass 4 claimed the idempotency holds ("recovery re-derives the chain");
  verified against source that only the `:create` branch re-derives, while the
  non-create branch destroys the passed struct and a second call raises. Adopted
  the consolidated review's option (a): make `discard/1` idempotent in A1
  (not-found/stale → already-discarded), double-discard covered in the
  cleanup-failure test.
- **Round-3 W4 (A1-1c's transaction presumes A1-3's repo requirement)**:
  **accepted** — coupling stated in A1-1c, with the parked-head-last destroy
  order as the repo-less fallback and the SQL-outbox requirement on the test.
- **Round-3 W5 (M-12 had no disposition)**: **accepted** — boot hydration and
  `chain_position` `:blocked` folded into the harness as A0-7/A0-8 (both
  load-bearing for this plan's own fixes); `SqlPassthrough` error branches and
  `RemoteContext` flush-threading declared follow-ups.
- **Round-3 S1 (BlockingLayer arms by layer, not call site)**: **accepted** —
  A0-3 now says drive a full miss and arm the wrapped cache layer just before
  the read.
- **Round-3 S2 (`:blocked` is computed, never persisted)**: **accepted** — A1-1
  reworded; tests assert flush behavior/`chain_position`, not a state value.
- **Round-3 S3 (validate path needs `validate_action/3` + the router call-site;
  B0-1 asserts actor and tenant together)**: **accepted** — B1-1/B1-4 now name
  the single signature change; B0-1 amended; B3-3's spec list updated to the new
  arity.
- **Round-3 S4 (the R-10 "check Gen" input is already known)**: **accepted** —
  committed to deleting `:applicable` and its dead gate.
- **Round-3 S5 (denied-set "clears on connect_params change" is unobservable
  in-process)**: **accepted** — verified `connect_params` is evaluated once in
  `init/1`; B2-3 reworded to "process state, resets with the socket," plus a fix
  for the misleading source comment.
- **Round-3 nits (moduledoc location of the write_through spec; `apply_result/6`
  clause count; duplicated `kick_next`/`:for_record`)**: **accepted** — A4-6
  added; A2-1(b) reworded; A1-1(d) carries the change-both-or-extract note.
- **Pass 4 S1 (stray space in a Facts path)**: **accepted** — fixed.
- **Pass 4 S2 (name the cleanup transaction mechanism)**: **accepted** — A1-1c
  names `Ash.DataLayer.transaction(outbox, ...)` around the `Ash.destroy!`
  calls.
- **Round-3 review W (a broad force-back would push unloaded/nil values into the
  local write)**: **accepted** — moot after dropping the force-back; its
  tightened wording (changed attributes + Ash-level defaults only, never
  NotLoaded) is preserved in A1-2 for the only path that could ever reintroduce
  one.
- **Round-3 review S (structured rebase-cleanup error, not a bare atom)**:
  **accepted** — A1-1's cleanup error now carries the cause plus the parked
  head/chain identity.

### Round 4 (on the thrice-amended plan) — converged

- **Round-4 review W (write_through target pushes could include
  `%Ash.NotLoaded{}` fields on updates from partially selected records —
  `Target.upsert` passes no `:fields` and `Backfill.upsert_record` defaults to
  all attributes)**: **accepted** — verified both call sites; A1-2 now threads a
  `:fields` option (loaded ∪ changed ∪ PK, excluding NotLoaded) through the
  push, and A0-2 gained the partial-select sub-assertion as its regression.
- **Round-4 S1 (A0-2's materialization sub-assertion is green pre-fix by
  construction — the current code pushes `local_write`'s return — so it cannot
  sit in a "must fail" gate)**: **accepted** — A0 heading and gate reworded; the
  sub-assertions are marked arbitration/gap-fill ("regression-protect the
  reorder", not "gate it"); A0-2's gate-carrying half is the
  errors-and-local-unchanged assertion. This also resolves the round-4 review's
  suggestion about the phase title.
- **Round-4 S2 (the Facts `apply_result/6` bullet kept the imprecise round-2
  phrasing that A2-1(b) had already corrected)**: **accepted** — Facts bullet
  aligned with A2-1(b).
- **Round-4 nit (the cleanup transaction re-raises; the structured-error
  contract needs a rescue at `rebase/2`)**: **accepted** — A1-1c now states the
  rescue-and-wrap explicitly.
- **Round-4 nit (mangled emphasis at the old line 80)**: **accepted** — the
  sentence was rewritten in the round-4 A0-2 edit; mangling check clean.
- **Round-4 nit (Round-2 W2 disposition retains superseded `:blocked`
  phrasing)**: **acknowledged, intentionally unchanged** — dispositions are
  historical records; the plan body carries the corrected computed-position
  wording.
- **Pass 5 S1 (the nil-PK guard is narrower than the documented "DB-generated
  fields unsupported" limitation)**: **accepted as a documented width mismatch**
  — the guard covers the catastrophic case (PK); non-PK DB-generated fields are
  doc-covered only, with a DSL-level guard deferred to A5 if wanted. Noted in
  A1-2.
- **Pass 5 retraction**: the pass-4 reviewer withdrew their `discard/1`
  idempotency claim after re-reading the source ("I generalized from the
  `:create` branch to the whole function") — independently confirming the
  Round-3 W3 adjudication.
- **Round-4 verdicts**: consolidated review — "0 criticals, 0 warnings … this
  plan has converged; no further pre-implementation review round is warranted —
  the next thing this plan needs is Phase A0." Second reviewer — 0 criticals;
  its one warning is the field-filtering item above, folded in. Pass 5 — "0
  critical, 0 warnings … Ship it."
