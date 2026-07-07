# Review: whole-repo code & architecture (ash_multi_datalayer + ash_remote)

**Date**: 2026-07-06 **Scope**: full `lib/` of both repos (`example/` in
ash_remote reviewed lightly), at ash_multi_datalayer `e0c0ed1` / ash_remote
`621129b`. Docs freshness findings from the same review were fixed the same day
and are not listed here. Sensitive-info findings were resolved or accepted
(git-history paths and demo dev secrets: accepted as harmless by the owner).
**Consumed by**: [the fix plan](../plans/20260706-review-findings-fix-plan.md).

Severity scale: HIGH = silent divergence/data exposure with no repair path; MED
= wrong behavior with an operational workaround; LOW = quality/hygiene.

## ash_multi_datalayer

Overall: the orchestrator/strategy seam is clean and the ProvenCoverage
read/invalidate path is battle-hardened (epoch protocol, property suites). The
rigor is asymmetric: the LocalOutbox **resolution/API surface** has ordering
bugs and swallowed errors of exactly the class the rest of the codebase defends
against. Secondary risk: the transitional "Phase 4a" debt (ProvenCoverage
options/capability logic in the shell and `Info`) is real leakage.

### M-1 [HIGH] `rebase/2` destroys the outbox entries created by its own resolution write

`lib/ash_multi_datalayer/orchestrator/local_outbox/api.ex` (`rebase/2`): applies
the changeset first (`Ash.create!/update!/destroy!` → LocalOutbox write path →
fresh `:pending` entries for the same `(resource, record_pk, target)`), **then**
calls `drop_chain(entry)`, which destroys every non-`:synced` entry for that key
— including the fresh ones. Unless the async flush wins the race, the resolution
is durable locally but never replicated; a later `refresh(:all)` then overwrites
the local resolution with the stale remote row (the empty outbox means the
dirty-chain rule cannot protect it). `rebase/2` has zero test coverage. Also:
the new entries enqueue while the parked ancestor still exists, so they'd be
`:blocked` behind it anyway. **Fix direction**: drop the parked chain _before_
applying the changeset.

### M-2 [HIGH] `write_through` commits local first, violating its documented invariant

`lib/ash_multi_datalayer/orchestrator/local_outbox/write.ex`
(`write_through/3`): the moduledoc promises "write every replica target
synchronously _first_, then the local layer; a replica failure fails the whole
action with nothing committed" — the code does
`drain_chain_inline → local_write → push_all_targets`. Local layers without
transactions (ash_sqlite/ETS) cannot roll back, so on target failure the caller
gets an error while the local row exists, with **no outbox entry to repair it**
(write_through deliberately writes none); a later full `refresh` treats the row
as a remote deletion and deletes the user's write. The existing test asserts
only `entries() == []` after failure, never local-layer state. **Fix
direction**: reorder to match the moduledoc (targets first, then local).

### M-3 [HIGH-MED] Reconcile ghost eviction escapes the epoch protocol

`lib/ash_multi_datalayer/orchestrator/proven_coverage.ex` (`maybe_backfill` →
`reconcile`): `epoch_moved?` is checked once at the top, but `reconcile`
physically destroys any cached row in the scan region absent from _this
reader's_ (possibly stale) `fetched_pks` — with no epoch guard and no epoch bump
of its own. Race: reader R1 starts backfilling Q; writer W creates row `r`
(bumps epoch, propagates `r`); reader R2 fetches (includes `r`) and records
entry P (postdates W's bump, so record succeeds); R1's reconcile finds
`r ∉ fetched_pks` and destroys it. Entry P survives, claiming coverage of a
region whose row was just deleted → lasting missing-row cache hit. **Fix
direction**: make ghost eviction participate in the epoch protocol — bump the
invalidation epoch (or drop entries covering the evicted PK,
`Invalidation.on_write`-style) per eviction so concurrent `record`s abort.

### M-4 [MED] Async write without a co-commit repo: orphaned local write + raise

`lib/ash_multi_datalayer/orchestrator/local_outbox/write.ex` (`async_run` /
`in_transaction`): when `co_commit_repo/3` is `nil` (local ETS layer, outbox on
SQLite — nothing rejects this config), the local write is durable and then
`Ash.create!` on the outbox raises on failure: a committed local write with no
outbox entry (silent permanent non-replication), surfaced as an exception
instead of `{:error, _}` from a data-layer callback. **Fix direction**:
`validate_opts` requires (or loudly warns on) non-co-commit configurations;
enqueue failures are caught and returned as `{:error, _}`.

### M-5 [MED] `discard_local/1` ignores its local-write result; `boot_hydrate` swallows silently

`api.ex` (`discard_local/1`): the `Backfill.destroy_record` /
`Backfill.upsert_record` results are discarded; on local-write failure
`drop_chain(entry)` still runs — the only record of the disagreement is
destroyed while local still holds the un-discarded value. `api.ex`
(`boot_hydrate`): ends in `rescue _ -> :ok` with no log — a failed
`hydrate: :on_start` leaves an empty local authority with zero diagnostics.
**Fix direction**: propagate the write result before `drop_chain`; log the
hydrate failure (warn) like `ExternalChange` does.

### M-6 [MED] Flush error taxonomy: auth failures classified `:transient`; bare conflict tuple

`lib/ash_multi_datalayer/orchestrator/local_outbox/flush.ex` (`classify/1`):
only `Ash.Error.Invalid` / `class: :invalid` is `:rejected`;
`%Ash.Error.Forbidden{}` falls to the `:transient` catch-all, burning the retry
budget before parking as `:transient_exhausted` — masking an expired token (the
_likely_ production failure; `RemoteContext` exists precisely for
background-push auth) as flakiness. Also `write.ex` `drain_chain_inline` halts
with `{:error, {:conflict, remote}}` — an opaque bare tuple to Ash callers.
**Fix direction**: classify `class: :forbidden` as its own park class (immediate
park, `error_class: :auth`); wrap the conflict in a structured error.

### M-7 [LOW-MED] Hit-path phantom absence during updates

`lib/ash_multi_datalayer/coverage/invalidation.ex` evicts the before-image row,
then `WriteDispatch.propagate` re-upserts the fresh record; a reader between the
two sees a state (row absent) that never logically existed. **Fix direction**:
upsert-in-place for updates (evict only on destroy / PK-change), or document the
anomaly explicitly.

### M-8 [LOW] `rollback/2` fallback throws a term nothing catches

`lib/ash_multi_datalayer/data_layer.ex` (`rollback/2` fallback):
`throw({:rollback, term})` with no matching catch in the `transaction/4`
fallback → `nocatch` crash instead of `{:error, term}`. **Fix**: wrap the
fallback `fun.()` in `try/catch` for `{:rollback, term}`.

### M-9 [MED, structural] Phase 4a debt: ProvenCoverage leaks through the strategy seam

`Coverage`/`WriteDispatch`/`Divergence`/`KillSwitch` at library root are
ProvenCoverage-only; `DataLayer.Info` exposes eight ProvenCoverage getters; the
DSL offers `ledger_max_entries`/`divergence_sampler`/aggregate toggles to every
resource (silently inert under LocalOutbox); `disable!/1` documents routing
behavior LocalOutbox ignores entirely. `default_can?`/`layers_can?` in the shell
duplicate `ProvenCoverage.can?/2` nearly clause-for-clause
(`@foldable_aggregate_kinds` is defined twice) and are almost unreachable. **Fix
direction**: move strategy opts into `orchestrator {Mod, opts}`,
`ValidateOrchestrator` rejects foreign opts, consolidate `can?`, and document
per-strategy kill-switch semantics.

### M-10 [LOW] Module size / cohesion

`ProvenCoverage` (~850 lines) mixes read routing, remainder planning,
aggregates, backfill, reconcile/eviction; `LocalOutbox.Api` (~460 lines) mixes
queries, resolution verbs, Oban control, refresh, hydration. Split
reconcile/eviction and aggregates out of `ProvenCoverage`; group `Api`.

### M-11 [LOW] Read-path redundancy; duplicate-fingerprint entries; misc hygiene

A miss normalises the same filter up to three times; `covers?` /
`Invalidation.on_write` are O(ledger) scans; every hit rewrites the whole
`Entry` for LRU. Two racing recorders can insert duplicate-fingerprint entries
(bloat only). `flush.ex`/`api.ex` use `String.to_existing_atom` on
`entry.resource` (raises before the module is loaded — boot-ordering artifact).
`LocalOutbox.Api` public surface has no `@spec`s. `ExternalChange.notify/1`
rescues exceptions but not `:exit`/`:throw` despite its "never crash the
notifying socket" contract.

### M-12 Test gaps

`rebase/2` (none), `write_through` failure local-state, boot hydration
(`:on_start`/`:if_empty`), `Flush.chain_position` `:blocked` path, `classify/1`
taxonomy, `discard_local` failure, `SqlPassthrough` error branches,
`RemoteContext` threading into flush pushes.

## ash_remote

Overall: transport/protocol/data-layer separation is clean; wire format is
versioned JSON; no unsafe deserialization (filters re-parsed server-side via
`Ash.Query.filter_input`); the manifest `Literal`/`Expression` mirroring is the
most security-conscious part. The recent destroy fix, source-map fan-out, and
ExternalChange integration were checked and are sound. The two most serious gaps
are missing enforcement seams at the transport/Ash boundary.

### R-1 [SECURITY HIGH] Tenant never crosses the RPC wire

`lib/ash_remote/data_layer.ex`: `set_tenant/3` stores tenant on the query;
`run_query/2`, `write/5`, `destroy/2` never encode it; `Protocol.build_run` has
no tenant key; headers carry only auth. The server resolves tenant from the conn
(`server/router.ex`), which the client cannot populate. Multitenant reads/writes
run with `tenant: nil` — raising at best, crossing tenant boundaries at worst.
Realtime _does_ carry tenant (topic), so the asymmetry is easy to miss. No e2e
tenant test exists. **Fix direction**: add `tenant` to the protocol body, thread
`query.tenant`/`changeset.to_tenant` through all three paths, server prefers the
wire tenant; e2e multitenant test.

### R-2 [SECURITY MED] Atom-table exhaustion from the untrusted `resource` param

`lib/ash_remote/server.ex` `resolve_resource` and
`lib/ash_remote/server/channel.ex` `resolve_resource` both call
`Module.concat([module_string])` on client input _before_ the membership check —
every distinct string interns an atom (the channel's `rescue ArgumentError`
doesn't help; `Module.concat` doesn't raise). Reachable pre-auth. **Fix
direction**: precompute a string→module map of the exposed surface and look up;
same fix both sites.

### R-3 [SECURITY MED] Realtime payloads bypass field policies

`lib/ash_remote/server/notifier.ex` `payload/4` serializes **every public
attribute** once with no subscriber actor; `channel.ex` `handle_out` gates whole
rows only. A row-visible subscriber receives fields RPC would deny. **Fix
direction (chosen)**: strip attributes that carry field policies from the wire
payload (fetch them via authorized RPC read), and document that realtime
otherwise delivers all public attributes.

### R-4 [SECURITY LOW] Exposure without authorizers is fully open; actor missing from validate

`server.ex` `run_action` — correct Ash posture, but `expose` on a policy-free
resource is an unauthenticated open door with no warning; `validate_action`
doesn't thread the actor. **Fix direction**: verifier warning for exposed
resources without authorizers; prominent moduledoc note; pass actor into
`validate_action`.

### R-5 [SECURITY LOW] Verbatim server error messages

`server.ex` `safe_message/1` returns `Exception.message(error)` for any rescued
error — non-Ash errors may leak internals. **Fix direction**: generic message
unless `Ash.Error.Invalid`/`Forbidden`/`NotFound`; log detail server-side.

### R-6 [MED] Transport failures return raw tuples, not Ash errors

`data_layer.ex`: `{:transport_error, reason}` / `{:http_error, status, body}`
pass through unwrapped on the backend-down path — the one path retry/circuit
logic needs a stable error type on. **Fix direction**: dedicated
`AshRemote.Error.Transport` Ash error.

### R-7 [MED] `upsert/3` is a non-atomic read-then-write

`data_layer.ex` `upsert`: remote read then create-or-update in two round trips;
concurrent flushes can double-create or lose an update — and this is
LocalOutbox's core replication primitive. **Fix direction**: handle the
create-collision (unique-constraint error → retry as update); document the
residual race; prefer a server-side identity upsert when available.

### R-8 [LOW] Manifest loader mints atoms from possibly-remote documents

`manifest/loader.ex` `atom/1` uses `String.to_atom` and `load/2` accepts http(s)
URLs. **Fix direction**: `String.to_existing_atom` for known Ash vocabulary;
document the trust requirement.

### R-9 [LOW] `join_denied` topics rejoin on every reconnect

`realtime/connection.ex` `handle_topic_close({:failed_to_join, _})`: denial is
logged and swallowed, but `handle_connect` re-attempts every topic — a durable
denial drives a `:join_denied` → LifecycleGuard full-reconcile storm forever.
**Fix direction**: track denied topics; exclude from rejoin until connect_params
change.

### R-10 [LOW] Misc

`Filter.encode` `:applicable` gate is dead (`remote_config/1` hardcodes `nil`) —
wire it from the manifest's `filter_operators` or drop it. `ClientId`
persistent_term is keyed by base_url only (two named `Realtime` supervisors
clobber echo-correlation; restarts trigger global GC). Public
`server.ex`/`data_layer.ex` functions lack `@spec`s.

### R-11 Test gaps

RPC-path tenant (none), transport-failure surfacing through data-layer
callbacks, upsert collision, field-policy realtime leak, unknown-resource atom
exhaustion.
