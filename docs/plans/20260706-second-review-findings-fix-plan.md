# Plan: fix the 2026-07-06 second-review findings

**Date**: 2026-07-06
**Input**: [second whole-repo review findings](../reviews/20260706-second-review-findings.md).
**Scope**: code and tests in `ash_multi_datalayer` plus the sibling
`../ash_remote` repository. This plan covers all HIGH and MED findings from the
second review and triages LOW findings into the first safe cleanup batch.
**Discipline**: repro first for every behavior change. A phase is not complete
until its new tests fail on the unfixed code for the stated reason, pass after
the fix, and the touched repo's full suite passes.

## Invariants being restored

1. **A client can only ask for public fields** (#1, #27): RPC field selection and
   serialization must respect Ash public fields and field-policy denial. Private
   attributes and forbidden fields are never exfiltrated and never crash JSON
   encoding.
2. **Coverage can never resurrect stale physical rows** (#2, A1, A2, A3, A4,
   A5): a read that loses a race, fails reconciliation, or receives an external
   notification may not leave a covering ledger entry over ghosts or stale row
   images.
3. **Tenant partitioning is canonical** (#3, #19, B2, A5): every read, write,
   outbox entry, invalidation, target call, and notification derives the same
   tenant partition key from the resource's multitenancy strategy.
4. **LocalOutbox has durable recovery and idempotent resolution** (#4, #5,
   #13-#19): a committed local write either has an enqueued/recoverable job or
   returns an error; retries do not park already-applied writes; resolution verbs
   are state-guarded, chain-head-only, and idempotent.
5. **Protocol boundaries do not crash or mint unsafe runtime state** (#6, #7,
   #10, #11, #24, #25): manifests, filters, sorts, errors, and decoded values are
   accepted only when they can be represented safely and faithfully.
6. **Data-layer dispatch follows Ash's public contracts** (B1, B3, #20, #21,
   #22): MDL must not bypass Ash dispatchers, call optional callbacks without
   guards, advertise unimplemented capabilities, or accept unsound layer order.

## Landing order

1. **Workstream R phase R1 must land before or with Workstream A phase A6**:
   A6's auth parking depends on `ash_remote` mapping HTTP 401/403 to the
   forbidden/auth error class (#9).
2. **Tenant canonicalization lands before LocalOutbox queue/target fixes**:
   #19's target threading and chain filters depend on the shared tenant key from
   A1.
3. **Upsert dispatch and error normalization land before propagation/backfill
   field fixes**: findings B1 and B3 affect the same `Backfill` and
   `WriteDispatch` boundaries as #12.
4. **Security fixes in `ash_remote` can land independently and should be first
   in that repo**: #1, #7, #10, and #27 close exfiltration/injection/crash
   surfaces and do not depend on MDL.

---

## Workstream A - ash_multi_datalayer

### Phase A0 - regression harness for MDL and LocalOutbox

**Findings covered**: #2-#5, #12-#23, A1-A5, B1-B3, selected LOWs.

**Change**:

1. Add targeted integration tests under `test/integration/` for ProvenCoverage
   races, tenant invalidation, LocalOutbox recovery/resolution, and propagation
   field handling.
2. Add focused unit tests near the owning modules for capability reporting,
   no-rollback tuple normalization, string-range interval handling, and optional
   callback guards.
3. Reuse existing blocking/stub layer support where possible; add only the
   minimum test helper extensions needed to force the reviewed race windows.

**Required failing repros before fixes**:

1. **#2 racing backfill resurrection**: block a read after physical
   `Backfill.upsert_records`, concurrently destroy the row, let
   `Coverage.record` return `:epoch_moved`, then assert the just-written cache
   rows are evicted and the next read does not serve the deleted row.
2. **A1 reconcile scan failure records coverage**: force `scan_layer_ghosts` to
   error on a degraded cache layer and assert no coverage entry is recorded for
   the region.
3. **#3/B2 tenant mismatch**: context-strategy with `%Organization{}` tenant and
   attribute-strategy resources both show a write invalidating the exact coverage
   partition that a prior read recorded.
4. **B1 upsert arity**: SQLite authority upsert and Postgres cache backfill do
   not raise `UndefinedFunctionError`.
5. **B3 no-rollback tuples**: destroy, propagation, and backfill normalize
   `{:error, :no_rollback, reason}` instead of raising `CaseClauseError`.
6. **#4 lost kick recovery**: create a pending entry without a job, run the
   sweeper, and assert the chain is enqueued; assert flush insertion errors are
   surfaced or persisted rather than discarded.
7. **#5 already-applied retry**: remote already equals `payload` while entry is
   still pending; retry returns `:ok` and marks synced instead of parking a
   conflict. Cover both worker flush and inline drain.
8. **#12 NotLoaded propagation**: partial-select update through propagation and
   async flush never writes `%Ash.NotLoaded{}` or nulls for untouched fields.
9. **#13 refresh TOCTOU**: a local write racing between dirty-check and refresh
   backfill is not clobbered.
10. **#14 write_through drain race**: worker re-check/lock prevents a stale
    in-flight flush from regressing the target after inline drain.
11. **#15 write_through local failure after target push**: target divergence is
    compensated or durably recorded.
12. **#16 discard chain behavior**: discarding a non-create head kicks the next
    entry; create discard and drop-chain destroy newest-first transactionally.
13. **#17 resolution verb state guards**: retry/force/discard/rebase reject
    non-parked or non-head entries and are idempotent on repeated calls.
14. **#18 remote read failures**: `discard_local`, `refresh`, and `hydrate`
    return structured errors on target read failures instead of match crashes.
15. **#19 tenant threading**: entry-driven target calls and chain filters include
    the entry tenant and do not cross-interfere on colliding PKs.
16. **#20 default_can?**: unsupported bulk create, aggregate query, and aggregate
    filter capabilities report false unless the underlying layer exports the
    required callback.
17. **#21 ExternalChange notifier**: local notifications are ignored unless they
    carry the external/replayed marker; optional handlers are function-exported.
18. **#22 verifier**: ProvenCoverage rejects a layer order where the read source
    authority is not the write authority.
19. **#23 aggregate-fold cold cache**: non-recordable limited/distinct aggregate
    queries return resolved aggregate values or fall through, never silent
    `%Ash.NotLoaded{}`.
20. **A2-A5**: external update notifications drop entries using a PK-unknown
    before image, composite PKs do not crash, string range subsumption is refused
    unless safe, and changeset-less tenant notifications invalidate the right
    partition or conservatively sweep all partitions.

**Verify**:

1. Each repro fails on the current code for the reviewed reason before any fix is
   applied.
2. `mix test test/integration` passes after each phase that touches integration
   behavior.
3. Full `mix test` passes before leaving Workstream A.

**Depends on**: none.

### Phase A1 - canonical tenant partitioning

**Findings covered**: #3, B2, #19 chain-filter half, A5.

**Change**:

1. Introduce one private tenant-key helper at the MDL boundary that derives the
   ledger/outbox partition from the resource's multitenancy strategy:
   context-strategy uses the converted Ash tenant (`to_tenant`); attribute
   strategy extracts the key from the resource's configured multitenancy
   attribute (`Ash.Resource.Info.multitenancy_attribute/1` + `Map.get(record,
   attr)`) because Ash does not set `query.tenant` for attribute tenancy. The
   helper must use that same extracted attribute value on read rows, write
   before/after images, outbox entries, and notification records rather than
   mixing `nil`, raw `changeset.tenant`, and `:__global__`.
2. Use the helper in read coverage recording, write invalidation, outbox chain
   filters, `kick_next`, and notification invalidation.
3. In `Backfill`, use `Ash.Changeset.set_tenant/2` or the equivalent Ash API so
   writes carry the converted tenant to the delegated layer.
4. For changeset-less notifications, derive tenant from the record's
   multitenancy attribute when available; otherwise sweep all tenant partitions
   for that resource/PK rather than invalidating `:__global__` only.

**Verify**:

1. Context tenant struct repro for #3 passes.
2. Attribute tenancy repro for B2 passes.
3. Changeset-less notification repro for A5 passes.
4. Existing context-tenant tests remain green.

**Depends on**: A0 failing tenant repros.

### Phase A2 - Ash data-layer dispatch and boundary normalization

**Findings covered**: B1, B3, #20, #21 optional callback half.

**Change**:

1. Replace direct `Ash.DataLayer.run_upsert/4` and `/5` calls in
   `WriteDispatch`, `Backfill`, and `LocalOutbox.Write` with the public
   `Ash.DataLayer.upsert/4` dispatcher or a local arity guard that exactly
   mirrors Ash's dispatcher.
2. Normalize `{:error, :no_rollback, reason}` to `{:error, reason}` at every MDL
   data-layer boundary before pattern matching.
3. Tighten `default_can?` so MDL returns false for callbacks it cannot actually
   execute, including bulk create, aggregate queries, and aggregate filters.
4. Guard optional orchestrator callbacks with `function_exported?/3`.

**Verify**:

1. SQLite-authority and Postgres-cache upsert repros pass.
2. No-rollback tuple tests pass without `CaseClauseError`.
3. Capability tests prove unsupported operations are not advertised.
4. `mix test` for affected unit/integration suites passes.

**Depends on**: A0 failing dispatch repros.

### Phase A3 - ProvenCoverage stale-row and reconcile safety

**Findings covered**: #2, A1, A2, A3, A4, #23, selected LOW coverage items.

**Change**:

1. When `Coverage.record` reports `:epoch_moved` after physical backfill, evict
   the just-written `source_rows` from cache layers and drop any covering ledger
   entries for those rows.
2. On reconcile scan failure, skip coverage recording for the affected region;
   do not convert an unknown cache state into a trusted hit.
3. For external update notifications, call invalidation with a PK-only unknown
   before image and the concrete after image so filter movement always drops
   possibly affected entries.
4. Refuse string/CiString range subsumption for `<`, `<=`, `>`, `>=` unless the
   bounds are equal or a future explicit C-collation option is configured.
5. Fix composite-PK miss paths by using `Map.take(row, primary_key)` anywhere the
   code currently assumes `[pk]`.
6. Add an aggregate-fold post-check that ensures output aggregates are resolved;
   non-recordable aggregate queries should fold against authoritative fetched
   rows or fall through, not replay against an empty cache.
7. Low-priority hardening in the same files: rescue ETS `ArgumentError` in
   `Coverage.insert/2`; store and compare canonical dedupe terms instead of bare
   `phash2`; add idle/global ledger caps only if the implementation is small and
   isolated, otherwise leave a documented follow-up.

**Verify**:

1. #2, A1, A2, A3, A4, and #23 repros pass.
2. Existing interval property tests pass.
3. Coverage debug/inspect tests continue to pass.
4. Full `mix test test/integration` passes.

**Depends on**: A1 tenant canonicalization and A2 boundary normalization.

### Phase A4 - LocalOutbox durable enqueue and sweeper

**Findings covered**: #4, #16 kick recovery, LOW synced pruning/rowid job key.

**Change**:

1. Implement the MDL-owned periodic sweep worker promised by the comments, or
   explicitly re-enable ash_oban's scheduler if that is the smaller correct
   design after checking the current supervision tree.
2. The sweeper finds `:pending` entries without live jobs and enqueues them,
   respecting per-record chain order and tenant partitioning.
3. Stop discarding `Enqueue.flush`/`Oban.insert` errors. Either surface them from
   the operation while the local transaction can still fail, or persist enough
   state for the sweeper to recover deterministically.
4. Include a stable write reference in the Oban uniqueness key, or otherwise
   prevent SQLite rowid reuse from inheriting stale job backoff for a distinct
   entry.
5. Add a small pruning path for old `:synced` entries if it can be implemented
   without changing user-visible retention semantics; otherwise document the
   retention follow-up in the runbook.

**Verify**:

1. Lost-kick repro passes.
2. Same-PK blocked tail is eventually kicked after the head resolves.
3. Oban uniqueness test proves a discarded max-seq entry does not poison a later
   entry.
4. Supervisor starts cleanly with the sweeper in test and normal configs.

**Depends on**: A1 tenant canonicalization.

### Phase A5 - LocalOutbox flush, stale-check, and resolution correctness

**Findings covered**: #5, #13-#18, #19 target-call half, selected LocalOutbox
LOWs.

**Change**:

1. In `stale_check`, if the remote row already equals the entry `payload`, treat
   the flush as successful. Apply the same guard to `drain_chain_inline`.
2. Treat a missing remote row during an `:update` with non-nil `base_image` as a
   conflict, not as permission to resurrect. Document the `:upsert` stale-check
   semantics or add an explicit guard if the current behavior is unsound for the
   configured target.
3. Thread `entry.tenant` through every entry-driven `Target` and `Backfill` call:
   flush push, stale-check, force, discard_local, and chain filters.
4. Make `refresh/3` and delete reconciliation atomic with the dirty check using
   the real co-commit Ecto repo transaction, not `Ash.DataLayer.transaction`.
   AshSqlite reports `can?(:transact) == false`, so Ash's transaction shell runs
   the function bare on the flagship stack. Resolve the shared repo the same way
   the async write co-commit path does (`co_commit_repo/3`) and call
   `repo.transaction(fn -> ... end)` directly, or use an equivalent watermark
   guard that the test proves closes the TOCTOU.
5. Prevent `write_through` inline drain from racing an already-running worker:
   use a per-PK lock/queue pause or have the worker re-read entry existence and
   state immediately before pushing.
6. For `write_through` target-success/local-failure, either compensate by
   re-pushing the pre-image or persist a divergence record that operators can
   resolve. Do not silently return an ordinary failure while targets hold the new
   value.
7. `discard/1` of a non-create head must kick the next entry. Create discard and
   `drop_chain` destroy newest-first inside the same real co-commit Ecto
   `repo.transaction`; do not use `Ash.DataLayer.transaction` for this atomicity
   claim on AshSqlite.
8. Fold in the rebase-transaction LOW: correct `destroy_captured_chain` to use
   the co-commit repo transaction as above, or, if parked-head-last partial
   cleanup is intentionally accepted as the fallback, fix the misleading comment
   and `RebaseCleanupError` message so they no longer claim "nothing was
   destroyed" on AshSqlite.
9. Add resolution verb state guards: only parked chain heads may be retried,
   forced, discarded, or rebased. Re-fetch before applying; convert not-found or
   stale destroy into idempotent `:ok` where the desired final state is already
   true.
10. Add `{:error, reason}` clauses to `discard_local`, `refresh`, and `hydrate`
   remote reads.
11. Treat remote `not_found` on destroy push as idempotent success.

**Verify**:

1. #5 and #13-#19 repros pass.
2. Resolution verbs are safe under duplicate calls and stale handles.
3. A SQLite-backed outbox test proves refresh/drop-chain/rebase cleanup use a
   real repo transaction or have the documented parked-head-last partial-failure
   posture; no assertion may rely on `Ash.DataLayer.transaction` rolling back on
   AshSqlite.
4. Offline-first conflict-resolution tests still pass after the queue changes.
5. `mix test test/integration/local_outbox*` and full `mix test` pass.

**Depends on**: A4 sweeper/recovery and A1 tenant canonicalization.

### Phase A6 - propagation field selection and external error taxonomy

**Findings covered**: #9, #12.

**Change**:

1. Make `Backfill.default_fields` or the two unguarded callers filter to loaded,
   non-`%Ash.NotLoaded{}` fields plus primary key. Preserve the existing guarded
   behavior for write_through and read-path backfill.
2. Ensure async flush and `WriteDispatch.propagate/5` pass explicit `:fields`
   when records may be partially selected.
3. Update `Flush.classify/1` to park HTTP-level 401/403 as `:auth` once
   `ash_remote` phase R1 maps transport errors to forbidden. During any overlap,
   accept both old raw `{:http_error, status, _}` tuples and the normalized error
   shape.

**Verify**:

1. #12 partial-select propagation and flush repros pass.
2. #9 auth parking repro passes with `ash_remote` R1.
3. Existing propagation-failure tests still pass.

**Depends on**: A2 for boundary normalization; R1 for final 401/403 taxonomy.

### Phase A7 - verifiers, notifier origin, and docs for MDL behavior

**Findings covered**: #21, #22, LOW verifier/config/doc items.

**Change**:

1. Require an external/replayed origin marker in `notification.metadata` before
   `ExternalChange` calls `handle_external_change`.
2. Add a ProvenCoverage verifier requiring `List.last(read_order) ==
   hd(write_order)` or the equivalent authority relationship for the configured
   orchestrator.
3. Fix `Capability.collect/2` to inspect `simple_expression`.
4. Move `RejectMultiNode`'s config lookup to runtime if the option is intended to
   be runtime configurable; otherwise document it as compile-time.
5. Filter explicit supervisor `resources:` to MDL resources before grouping.
6. Extend aggregate-override typo checking to `fold_aggregate_overrides` and
   `local_evaluation_overrides`.
7. Update MDL guides/runbooks for new sweeper behavior, auth park class,
   resolution idempotency, tenant strategy rules, and known deferred LOW items.

**Verify**:

1. Verifier tests reject the unsound layer order.
2. Notifier tests prove local writes do not evict their own propagated rows.
3. DSL typo tests cover all aggregate override option groups.
4. `mix test` passes.

**Depends on**: A1, A3, A5.

---

## Workstream R - ash_remote

### Phase R0 - regression harness for RPC, manifest, transport, and realtime

**Findings covered**: #1, #6-#11, #24-#27, ash_remote LOWs.

**Change**:

1. Add RPC server tests for private field selection, field-policy-denied fields,
   manifest access policy/documentation, and tenant/actor propagation.
2. Add codegen/manifest tests using a fresh client project vocabulary so tests do
   not accidentally predefine open-vocabulary atoms.
3. Add malicious manifest tests for aggregate filter source injection, invalid
   identifiers, path traversal, non-string schema versions, enum values that are
   not legal bare atoms, and aggregate kinds not loaded by the mix task.
4. Add data-layer tests for unsupported filters, `false` filters, non-PK upsert
   identities, action-less backfill updates, decoded calc/aggregate casting, and
   path-safe error decoding.
5. Add realtime tests for LifecycleGuard registry restart, reconcile exits,
   join-denied/resubscribed delivery after restart, and subscription revocation
   posture where currently supported.

**Verify**:

1. Security/crash repros fail before fixes for the reviewed reasons.
2. Full `mix test` in `../ash_remote` is green after each phase.

**Depends on**: none.

### Phase R1 - RPC server field security and transport taxonomy

**Findings covered**: #1, #9, #27, server LOWs around manifest auth and join
revocation docs.

**Change**:

1. In server field resolution, resolve client-requested fields only through
   `public_attribute`, `public_calculation`, `public_aggregate`, and
   `public_relationship` equivalents. Apply this to both `to_select_and_load`
   and `serialize`.
2. In serialization, map `%Ash.ForbiddenField{}` and `%Ash.NotSelected{}` to nil
   or omit according to the existing wire contract; never pass them to Jason.
3. Normalize HTTP 401/403 transport errors to the forbidden/auth class consumed
   by LocalOutbox classification.
4. Document that `GET /manifest.json` must be mounted behind auth, or add a
   configurable hook if the server already has the right boundary for it.
5. Document current subscription revocation semantics and add a server hook only
   if it can be introduced without changing the public channel contract.

**Verify**:

1. Private attribute exfiltration repro returns an error or omits the field.
2. Field-policy-denied selection returns a successful response with safe values
   or a typed client error, not a raw 500.
3. 401/403 transport normalization tests pass.
4. Server RPC suite passes.

**Depends on**: R0 failing RPC/transport repros.

### Phase R2 - manifest loader and code generator hardening

**Findings covered**: #6, #7, codegen LOWs.

**Change**:

1. Stop applying `String.to_existing_atom` to open-vocabulary identifiers such as
   primary keys, relationship source/destination attributes, identity keys, and
   user-defined field names. Keep them as strings through loading and convert only
   at trusted generation points that can validate syntax.
2. Keep closed-vocabulary manifest values on `to_existing_atom` or explicit
   allowlists.
3. Gate generated aggregate filters with `AshRemote.Expression.safe?`; unsafe or
   unreproducible filters fall back to `remote(...)` proxies.
4. Validate all generated identifiers: module names, resource names, field names,
   enum values, relationship names, aggregate kinds, and file paths. Reject or
   quote safely rather than interpolating raw strings into source.
5. Prevent path traversal in `ash_remote.gen.ex` by deriving output paths only
   from validated module segments under the configured output root.
6. Return typed loader errors for non-string `schema_version` values.
7. Preserve FK type/nullability for generated `belongs_to` relationships and
   handle aggregates over many-to-many/private relationships by proxying or
   rejecting with a clear error.
8. Generate calc argument `allow_nil?` from manifest nullability instead of
   defaulting all args to true.

**Verify**:

1. Fresh-project FK/PK generation succeeds without pre-seeded atoms.
2. Malicious aggregate filter and path traversal manifests are rejected.
3. Benign unusual identifiers are quoted or rejected with typed errors, never
   syntax-erroring halfway through generation.
4. Codegen suite passes.

**Depends on**: R0 manifest/codegen repros.

### Phase R3 - data-layer encoding, upsert, decoding, and actor threading

**Findings covered**: #8, #10, #11, #24, #25, data-layer/encode LOWs.

**Change**:

1. Thread actor/context into bundled remote-calculation fetches and build request
   headers with the same auth path used by ordinary reads. Preserve tenant
   threading.
2. Stop minting atoms from server-controlled error paths. Keep path segments as
   strings or map unknown segments to a safe sentinel.
3. Make `can?({:filter_expr, expr})` return true only for shapes the encoder can
   encode. Short-circuit boolean `false` filters to an empty successful result.
4. Fix upsert resolution to build its lookup filter from `keys`, not only from
   primary key. For action-less backfill/update paths, bypass action `accept`
   truncation so all provided replicated fields converge.
5. Cast decoded query calculations and aggregates using their declared types.
6. Dedupe duplicate `authorization` headers by case-insensitive name with an
   explicit precedence rule.
7. Apply retry config only to idempotent read/run requests, not non-idempotent
   write POSTs.
8. Fix composite-PK assumptions in remote calculation request/response code.
9. Preserve parameterized calculation arguments in sort encoding.
10. Normalize malformed successful responses with missing `data` into typed
    protocol errors.
11. Keep `relationship_path` in filter references or reject references that would
    otherwise become silently unscoped.

**Verify**:

1. Actor-authenticated remote calculation repro passes.
2. Atom exhaustion repro cannot create new atoms.
3. Unsupported/false filter tests return fallback or empty results without
   crashing mid-request.
4. Non-PK identity upsert and action-less replicated update converge all fields.
5. Decimal/date calc and aggregate decode tests return typed values.
6. Data-layer suite passes.

**Depends on**: R0 data-layer repros.

### Phase R4 - realtime lifecycle and notification robustness

**Findings covered**: #26, realtime/server LOWs.

**Change**:

1. Have `LifecycleGuard` monitor the realtime registry and re-register on
   `:DOWN` after registry restart.
2. Wrap reconcile/gap reactions with `try/catch` for `:error`, `:exit`, and
   `:throw`, not only `rescue`.
3. Fix changeset-less multitenant mutation broadcasts so they publish to a
   joinable tenant topic or conservatively trigger a documented reconnect path.
4. Reduce per-subscriber refetch amplification for unknown filter evaluation if a
   shared per-resource/per-PK refetch cache can be added simply; otherwise add a
   benchmark-backed follow-up.
5. Update stale `connect_params` docs.

**Verify**:

1. Registry restart test proves later `:resubscribed` and `:join_denied` events
   reach the guard.
2. Reconcile exit test does not kill or permanently deafen the guard.
3. Multitenant broadcast test reaches the expected subscribers.
4. Realtime suite passes.

**Depends on**: R0 realtime repros.

---

## LOW finding disposition

### Fix in the phases above

1. Coverage ETS `ArgumentError` rescue, dedupe collision comparison, selected
   ledger cap/GC work if small: A3.
2. Capability `simple_expression`, runtime config or docs for `RejectMultiNode`,
   supervisor resource filtering, aggregate override typo checks: A7.
3. LocalOutbox rowid uniqueness, destroy idempotency, AshSqlite-safe real
   co-commit repo transactions for refresh/drop-chain/rebase cleanup, synced
   pruning or docs, destroy-missing success, stale-check missing remote/update
   behavior: A4/A5.
4. `ash_remote` authorization header dedupe, write retry scoping, composite PK
   remote calcs, sort calc args, malformed success response, relationship-path
   filter refs: R3.
5. Codegen aggregate kinds, path traversal, non-string schema version,
   belongs_to FK type/nullability, calc arg nullability, many-to-many/private
   aggregate handling: R2.
6. Realtime guard exit handling and stale docs: R4.

### Defer with explicit follow-up unless implementation is trivial while nearby

1. ProvenCoverage crash-safe pending/active ledger protocol. This is larger than
   the #2/A1 eviction fixes and should be designed separately if not handled by
   an existing phase.
2. Global cross-tenant ledger cap and epoch meta GC if not small enough for A3.
3. Divergence shadow-read epoch guarding, unless touched by A3 tests.
4. HostResolver persistent_term invalidation after hot code reload.
5. Server subscription revocation beyond documentation/hook support if it changes
   the public channel contract.
6. Per-subscriber refetch amplification if it needs a new cache/coalescing
   component.

---

## Final gates

1. `mix test` passes in `ash_multi_datalayer`, including integration tests.
2. `mix test` passes in `../ash_remote`.
3. The offline-first example exercises online invalidation, offline edit,
   conflict, and each resolution verb after the LocalOutbox changes.
4. Security repros for #1, #7, and #10 are retained in the suite and fail closed.
5. Tenant strategy tests cover context tenant structs, attribute tenancy, and
   changeset-less notifications.
6. Docs changed by semantics are updated: MDL guide/runbook, ash_remote server
   manifest/auth notes, LocalOutbox sweeper and park classes, codegen manifest
   validation notes, and changelogs/decision logs if the repo keeps them.

## Implementation notes

1. Keep each phase separately committable. Do not mix broad refactors with the
   behavior fixes unless a refactor is required to make the behavior testable.
2. Prefer using Ash public APIs over copying internal dispatcher behavior. If a
   local guard is unavoidable, cite the Ash callback contract in the code comment
   or test name.
3. For every race fix, the test must prove the reviewed interleaving, not merely
   the happy final state.
4. For every security fix, the test must assert both the blocked exploit and a
   legitimate allowed request still working.
5. If a phase uncovers that a finding has already been fixed by earlier work,
   keep or add the regression test and mark the phase item as verified rather
   than deleting it from the plan.

## Review disposition

Reviewed in
[20260706-second-review-findings-fix-plan-review.md](../reviews/20260706-second-review-findings-fix-plan-review.md):
**0 critical, 1 warning, 1 suggestion**.

1. **W1 accepted**: `Ash.DataLayer.transaction` is a no-op on AshSqlite, so A5
   now requires the real co-commit Ecto `repo.transaction` for refresh,
   drop-chain, and rebase cleanup atomicity. The rebase-transaction LOW is folded
   into A5 and the LOW disposition.
2. **S1 accepted**: A1 now spells out attribute-strategy tenant-key derivation via
   `Ash.Resource.Info.multitenancy_attribute/1` and `Map.get(record, attr)` so
   reads, writes, outbox entries, and notifications key the same partition.
