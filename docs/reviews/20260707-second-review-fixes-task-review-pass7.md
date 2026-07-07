# Review: `20260707-second-review-fixes/` task files, pass 7

**Date**: 2026-07-07
**Subject**: current task set in
[`docs/tasks/20260707-second-review-fixes/`](../tasks/20260707-second-review-fixes/)
after the pass-6 follow-up edits.
**Scope**: task executability, acceptance-criteria completeness, tracker
consistency, and targeted verification against `ash_multi_datalayer` plus the
sibling `../ash_remote` source.

## Findings

### High - H1 can close while still reusing wrong-actor remote calculation values

- **Task refs**: `h1-remote-calc-fetch-unauthenticated.md:30-45`
- **Source refs**: `../ash_remote/lib/ash_remote/remote_calculation.ex:68-86`,
  `../ash_remote/lib/ash_remote/data_layer.ex:320-335`

H1 requires threading actor/context headers into bundled remote-calculation
fetches, but the same code path also memoizes fetched bundles in the process
dictionary under `{pk_values, specs, tenant}` only. The memo key does not include
the actor, request headers, or auth-relevant context. Two loads in the same
process with different actors but the same tenant/PK/specs can reuse the first
actor's values even after the request itself starts carrying headers.

**Recommendation**: add an acceptance test with two same-process loads using
different actors or headers for the same tenant/PK/specs. Require the memoization
key or memoization scope to include auth-relevant context, or be cleared per load.

### High - H2 does not require updating by the row found through the non-PK identity

- **Task refs**: `h2-non-pk-upsert-identity-accept-truncation.md:39-58`
- **Source refs**: `../ash_remote/lib/ash_remote/data_layer.ex:198-214`,
  `../ash_remote/lib/ash_remote/data_layer.ex:230-247`

H2 now requires the initial lookup and collision retry lookup to use `keys`, but
the current source discards the found row and rebuilds the update changeset's
primary key from incoming attributes. A fix could correctly find the existing row
by non-PK identity, then still update using a missing or stale incoming PK.

**Recommendation**: add a repro where incoming changeset attributes lack the PK
or contain the wrong PK, the non-PK identity lookup finds the existing row, and
both the initial update path and create-collision retry update by the found row's
actual PK.

### High - L8 mutation authorization tests can pass through fetch denial only

- **Task refs**: `l8-rpc-authorize-flag.md:24-34`
- **Source refs**: `../ash_remote/lib/ash_remote/server.ex:395-408`,
  `../ash_remote/lib/ash_remote/server.ex:434-436`

L8 asks for read/create/update/destroy/fetch-helper coverage, but an update or
destroy test that only asserts an unauthorized RPC is denied can pass because
`fetch!/3` denies the read. That would not prove `Ash.update!/1` and
`Ash.destroy!/1` run with `authorize?: true` on the terminal mutation calls.

**Recommendation**: add update and destroy policy tests where the actor is
authorized to fetch/read the row but forbidden to mutate it. Add an analogous
create-policy denial test for create, independent of read/fetch behavior.

### Medium - L1 can close while leaving `pk_merge/3` composite-PK crashy

- **Task refs**: `l1-composite-pk-aggregate-paths.md:11-29`
- **Source refs**:
  `lib/ash_multi_datalayer/orchestrator/proven_coverage.ex:406-415`,
  `lib/ash_multi_datalayer/orchestrator/proven_coverage.ex:596-600`

The L1 defect and fix text correctly name both `add_aggregates_via_layer/5` and
`pk_merge/3`, but the done criteria only require a relationship-aggregate fold
path repro. `pk_merge/3` is on the separate remainder/partial-coverage path and
can retain its `[pk] = Ash.Resource.Info.primary_key(resource)` crash while the
listed repro passes.

**Recommendation**: add a second repro or done criterion for a composite-PK
partial/remainder coverage read that exercises `pk_merge/3`.

### Medium - L11 omits two `:no_rollback` normalizers from scope

- **Task refs**: `l11-no-rollback-signal-discarded.md:9-28`
- **Source refs**: `lib/ash_multi_datalayer/write_dispatch.ex:162`,
  `lib/ash_multi_datalayer/orchestrator/local_outbox/write.ex:208`,
  `lib/ash_multi_datalayer/orchestrator/local_outbox/write.ex:314`,
  `lib/ash_multi_datalayer/backfill.ex:103-108`,
  `lib/ash_multi_datalayer/backfill.ex:125-126`

L11 says to audit three call sites, but the source has five places that collapse
`{:error, :no_rollback, reason}` to `{:error, reason}`. The two `Backfill`
normalizers may be intentionally internal, but the task can currently close
without making or recording that decision.

**Recommendation**: add `backfill.ex` to the task scope and require each
normalizer either to preserve the 3-tuple when it propagates back to Ash's
transaction machinery or to document why normalization is safe at that boundary.

### Medium - H3 helper error criteria do not require `refresh/3` to return an error

- **Task refs**: `h3-refresh-toctou.md:41-50`
- **Source refs**:
  `lib/ash_multi_datalayer/orchestrator/local_outbox/api.ex:341-371`,
  `lib/ash_multi_datalayer/orchestrator/local_outbox/api.ex:377-388`,
  `lib/ash_multi_datalayer/orchestrator/local_outbox/api.ex:477-492`

H3 requires `reconcile_deletes` and `delete_local_pk/3` to return structured
errors instead of raising, but `refresh/3` currently places helper return values
directly in the success map's `deleted` field. A fix could make the helpers return
`{:error, reason}` and still return `%{deleted: {:error, reason}}` as a successful
refresh.

**Recommendation**: require `refresh/3` itself to propagate delete-reconciliation
helper failures as `{:error, reason}` and update the public specs/tests around
that shape.

### Medium - B3 acceptance does not explicitly forbid exact-attribute regex fixes

- **Task refs**: `b3-tenant-from-filter-dead-code.md:28-31`,
  `b3-tenant-from-filter-dead-code.md:82-106`
- **Source refs**: `lib/ash_multi_datalayer/tenant_key.ex:44-63`

B3's defect text calls out the `org` versus `organization_id` substring collision
and the unsoundness of `inspect`/regex parsing. The done criteria require
multi-predicate/`or`/`in` behavior and representation consistency, but they do
not directly require exact attribute identity or ban regex/`inspect` extraction.
A more careful regex patch could satisfy the listed checks while preserving the
same class of parser fragility.

**Recommendation**: add a done criterion requiring structural filter AST handling
or extracted-row derivation with exact tenant-attribute identity. Include an
`org`/`organization_id` collision test and explicitly reject `inspect`/regex
tenant extraction as a valid fix.

### Medium - M11 does not test explicit `data: null` where a list is required

- **Task refs**: `m11-decoder-crashes-nil-single-object.md:33-45`,
  `m11-decoder-crashes-nil-single-object.md:53-59`
- **Source refs**: `../ash_remote/lib/ash_remote/protocol.ex:62-63`,
  `../ash_remote/lib/ash_remote/decoder.ex:25-31`,
  `../ash_remote/lib/ash_remote/data_layer.ex:280-282`

The fix text correctly says `null` is malformed where the protocol requires a
list, but the done criteria only test explicit-null `get?` misses and missing
`data`. A blanket `nil -> []` fix could pass those checks while silently accepting
`{"success": true, "data": null}` for ordinary non-`get?` reads.

**Recommendation**: add an acceptance test that a normal non-`get?` read with
explicit `data: null` returns a typed protocol error, not `[]`.

### Medium - Retained-regression inventory is inconsistent

- **Task refs**: `00-index.md:84-91`, `00-index.md:235-239`,
  `pre-checkpoint-commit.md:12-18`,
  `b1-rpc-private-calc-aggregate-exfiltration.md:75-82`

The index's exemption list includes B1's first-run private-attribute fix as a
landed-but-untested retained regression, while the later "Five items need a
retained regression" list names only B1's #27 half and L12 items 3/4/5/8. PRE's
"six items" inventory likewise omits the B1 private-attribute half, while B1
itself explicitly requires that retained regression.

**Recommendation**: replace the scattered counts with one canonical retained-
regression table that distinguishes uncommitted fixed-in-tree items,
landed-but-untested items, and docs-only confirmations.

### Medium - Verification metadata contract is not true for every task file

- **Task refs**: `00-index.md:58-62`,
  `h5-localoutbox-nil-tenant-model.md:6`,
  `p6-lost-kick-recovery.md:3-14`,
  `p1-aggregate-guard-bypass.md:3-15`,
  `l12-mdl-misc-lows.md:3-12`,
  `l13-ash-remote-server-realtime-lows.md:3-10`

The index says each task file has a `Verification:` field with `VERIFIED` or
`AGENT`. Several task files have no `Verification:` field, and H5 uses the hybrid
value `VERIFIED / AGENT`. This weakens the index's promised distinction between
workflow status and confidence in the defect claim.

**Recommendation**: either add `Verification:` to every finding task or change
the index wording to "where present." Split H5 by subclaim or choose one canonical
value.

### Medium - A0/R0 ownership of changeset-less notification coverage remains blurry

- **Task refs**: `a0-mdl-repro-harness.md:20-24`,
  `r0-ash-remote-repro-harness.md:27-31`,
  `m8-changeset-less-multitenant-broadcast.md:40-44`,
  `final-gates.md:32-36`

A0 is the MDL harness, but it still lists "changeset-less notifications" in the
tenant-invalidation test bucket. FINAL points to A0/R0 and M8, while R0 only
mentions realtime tests generically. The explicit owner for the ash_remote
changeset-less multitenant broadcast repro is therefore split across files.

**Recommendation**: qualify A0's item as the MDL-side notification handling only,
and add an explicit R0/M8 done criterion for changeset-less multitenant broadcast
coverage.

### Low - B3's two-phase lifecycle is still implicit

- **Task refs**: `00-index.md:109-110`,
  `b3-tenant-from-filter-dead-code.md:65-72`,
  `b3-tenant-from-filter-dead-code.md:87-100`

B3 must land the canonical tenant function before H5/M2/L3/P4 are worked, but
B3's own done criteria also require all five tenant call sites to agree. That can
work if B3 remains open until the whole tenant unit lands, but the file does not
state that lifecycle explicitly.

**Recommendation**: state that B3 has two phases: the canonical function lands
first, and B3 closes only after the tenant-unit consumers are updated and the
five-call-site assertion passes.

### Low - Global status semantics do not fit PRE and other non-behavior tasks

- **Task refs**: `00-index.md:64-67`, `pre-checkpoint-commit.md:41-49`,
  `final-gates.md:64-72`

The index defines `DONE` as "repro test in suite + full suite green," but PRE can
complete by coordinated commits or recorded skip decisions and has no repro.
FINAL also allows PRE skip recording. The status model is therefore precise for
behavior fixes but not for cross-cutting/preflight/docs-only tasks.

**Recommendation**: add explicit status semantics for non-behavior tasks. Define
whether a PRE skip is `WONTFIX (reason)`, `DEFERRED`, or a valid `DONE` state with
a recorded skip decision.

### Low - A0 overstates that every task names an A0 repro

- **Task refs**: `a0-mdl-repro-harness.md:28-34`,
  `m1-upsert-skipped-badmaperror.md:38-44`,
  `b5-validate-aggregate-overrides-regression.md:46-55`

A0 says each per-finding task names its A0 repro. Several behavior tasks have
repro criteria but no numbered A0 repro reference. The implementation discipline
is still clear, but the statement is stronger than the task files support.

**Recommendation**: change the wording to "where applicable" or add explicit
A0/R0 repro ownership labels to every behavior-changing task.

### Low - L13 can close manifest schema disclosure as docs-only while the default route remains public

- **Task refs**: `l13-ash-remote-server-realtime-lows.md:14-16`,
  `l13-ash-remote-server-realtime-lows.md:36`
- **Source refs**: `../ash_remote/lib/ash_remote/server/router.ex:64-68`

L13 tracks unauthenticated manifest schema disclosure, but the done criterion is
"Manifest auth requirement documented (or hook added + tested)." The default
router still serves `/manifest.json` with no auth hook. If docs-only closure is
intentional, the task should make the accepted default exposure explicit.

**Recommendation**: either require a configurable auth hook/plug option with a
test, or reword the item as an explicit docs-only decision accepting the default
unauthenticated manifest route.

## Summary

- Findings raised: 15 total - 3 High, 8 Medium, 4 Low.
- The task set is materially stronger than pass 6, and no mechanically impossible
  sequencing blocker remains.
- The remaining risk is mostly acceptance criteria that can pass while leaving the
  root defect open, especially actor-scoped remote calculation memoization,
  non-PK upsert identity updates, and mutation authorization coverage.
