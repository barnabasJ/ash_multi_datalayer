# Second whole-repo review — new findings (2026-07-06)

Scope: `ash_multi_datalayer` (MDL) + `ash_remote`, targeting **new** issues
found _after_ the first review's fixes shipped (M-1..M-12 / R-1..R-11). None of
the below re-report an already-fixed finding.

Method: six subsystem review agents (ProvenCoverage, LocalOutbox, MDL core,
ash_remote data_layer/transport, ash_remote server/realtime, ash_remote
codegen/manifest); three areas were independently double-reviewed (LocalOutbox,
ProvenCoverage, MDL core), which added depth and cross-validated the
load-bearing findings. Every HIGH and the load-bearing MEDs were verified
end-to-end against source (including vendored `deps/ash`, `deps/ash_sqlite`,
`deps/ash_postgres`).

Severity legend: HIGH = data loss / silent staleness / security / crash on a
supported config; MED = correctness or robustness gap under realistic
conditions; LOW = narrow/defensive/perf/doc.

---

## Verification status

Personally traced end-to-end by the orchestrator: #1, #2, #3, #4, #5, #6, #7,
#8, #9, #10, #11, #16, #24, A1, A4, B1, B2, B3. The remainder rest on the
subagents' traced analysis with the cited line numbers; anchor lines
spot-checked. Areas explicitly cleared appear at the end.

---

## HIGH

### #1 [SECURITY] RPC returns private attributes — credential/PII exfiltration

`ash_remote/lib/ash_remote/server/fields.ex:104` + `server.ex:342-368`
`attribute?/2` uses `Ash.Resource.Info.attribute/2`, which matches **private**
fields; `dispatch(:read)` folds any wire-named field into `Ash.Query.select` and
`serialize` maps it into the JSON response. Ash's default
`private_fields_policy` is `:show`, so a field hidden the standard way
(`public?: false`, no field_policies) is fully exfiltratable:
`POST /rpc/run {"resource":"MyApp.User","action":"read","fields":["hashed_password"]}`
returns it. Filter/sort inputs correctly use the public-only
`filter_input`/`sort_input`; `fields` is the one unguarded client input.
**Fix:** resolve wire fields via `public_attribute`/`public_calculation`/
`public_aggregate`/`public_relationship` in both `to_select_and_load` and
`serialize`.

### #2 [MDL/ProvenCoverage] Racing backfill resurrects a deleted row

`ash_multi_datalayer/lib/ash_multi_datalayer/orchestrator/proven_coverage.ex:715-730`
The epoch protocol guards ledger _recording_, not physical rows. When reader A's
slow `Backfill.upsert_records` (:715) lands after a concurrent destroy bumped
the epoch, A's `Coverage.record` returns `:epoch_moved` — but :726 only emits
telemetry; it never evicts the pre-destroy rows A just wrote. A concurrent
reader C, which recorded a legitimate coverage entry in the gap, now owns those
orphan rows → every subsequent read is a cache hit serving the deleted row as
live. Update variant serves a stale value. **Fix:** on `:epoch_moved` after the
physical upsert, `Invalidation.on_evict` + physically evict the just-written
`source_rows`.

### #3 [MDL] Write invalidation uses the wrong tenant key → stale reads

`write_dispatch.ex:78` (+ `backfill.ex:63-67`) Reads key coverage by
`query.tenant` (the converted `to_tenant`); writes invalidate with the raw
`changeset.tenant`. With a struct tenant (`tenant: %Organization{}` +
`Ash.ToTenant` — the standard AshPostgres pattern) the pre-write coverage entry
survives under a different key and the next read is a stale hit. Invisible with
plain string tenants (identity conversion). **Fix:** use `changeset.to_tenant`
in dispatch and `Ash.Changeset.set_tenant/2` in Backfill. (See also B2 — the
attribute-strategy manifestation is worse.)

### #4 [MDL/LocalOutbox] The "MDL sweeper" does not exist — a lost kick strands a chain forever

`local_outbox/write.ex:220`, `sync/enqueue.ex:4`,
`sync/transformers/inject_outbox.ex:288` The durability story leans on an "MDL
sweep worker" (comments: "Phase 4 wires them", "Sweeping is MDL-owned" —
`scheduler_cron: false` disables ash*oban's own scheduler on its strength). No
such module exists; every reference is a comment. If the process dies between
the co-commit and the post-commit `Enqueue.flush`, or `Oban.insert` returns
`{:error,*}`(discarded at every call site), the`:pending` entry has no job and no recovery — later same-PK writes snooze forever behind it (`:racing`), and `await`hangs. **Fix:** implement the periodic sweep worker (or re-enable ash_oban's scheduler); stop discarding`Enqueue.flush`
errors.

### #5 [MDL/LocalOutbox] Retry after a partially-succeeded flush parks a succeeded write as a false conflict

`local_outbox/flush.ex:183` The remote push happens in `before_action`; marking
`:synced` commits separately. If the commit fails (routine SQLite
`Database busy`) or the worker crashes between them, Oban retries — the entry is
still `:pending`, and `stale_check` reads the remote (already holding the new
value) against `base_image` (old value) → `{:conflict, remote}`, parking a
fully-succeeded write for manual resolution. **Fix:** in `stale_check`, if the
remote already equals the entry's `payload`, return `:ok`. Same guard belongs in
`drain_chain_inline`.

### #6 [ash_remote/codegen] `to_existing_atom` over-applied — breaks legitimate first-time generation

`ash_remote/lib/ash_remote/manifest/loader.ex:263-265,273` (and PK at :175) The
R-8 hardening was wrongly extended to
`source_attribute`/`destination_attribute`/ identity-key/PK names —
**open-vocabulary, user-chosen identifiers**. On a fresh client project an FK
atom like `:todo_list_id` has never been defined, so `String.to_existing_atom`
raises the misleading "not a known Ash vocabulary atom" error against a valid
trusted manifest. The repo's own tests mask it (test resources define those
atoms). **Fix:** keep open-vocabulary identifiers as strings.

### #7 [ash_remote/codegen] Aggregate filter interpolated raw into generated source (code injection)

`ash_remote/lib/ash_remote/gen/generator.ex:371`
`filter expr(#{field.aggregate_filter})` splices a manifest JSON string with no
`AshRemote.Expression.safe?` gate — even though calc expressions (:334) and
validations (:165) are explicitly re-verified ("a manifest is input"). A crafted
manifest injects arbitrary code at compile time. Related: no identifier
sanitization anywhere in the generator (a benign enum value like
`:"in-progress"` also produces a syntax error; `ash_remote.gen.ex:81`
`Path.join` on module strings is a path-traversal vector). **Fix:** gate
`reproducible_aggregate?` on `Expression.safe?`, falling back to the
`remote(...)` proxy; validate identifiers.

### #8 [ash_remote, SECURITY] Bundled remote-calculation fetch runs unauthenticated

`ash_remote/lib/ash_remote/data_layer.ex:327`, `remote_calculation.ex:72`
`request(cfg, :run, body)` passes no headers, and `fetch_remote_calculations`
receives only `context.tenant` — **never the actor**. When rows were served by a
cache layer (or `Ash.load!(records, :remote_calc, actor: user)`), the bundle
request carries no Bearer token → the backend read denies a legitimate user or
returns values for no actor. Tenant is threaded; actor is a one-sided drop.
**Fix:** thread the calc actor/context into `fetch_remote_calculations` and
build `request_headers` from it.

### A1 [MDL/ProvenCoverage] Reconcile-scan failure still records coverage → unswept ghost servable forever

`proven_coverage.ex:816` When `scan_layer_ghosts` errors (flaky cache layer), it
returns `[]`, so `reconcile` evicts nothing — but `maybe_backfill` proceeds to
`Coverage.record` (:719), inserting a covering entry. If a prior write's
physical eviction of a destroyed row also failed on that same degraded layer
(correlated failure), every subsequent read is a hit that includes the ghost;
hits never re-run reconcile, so it never heals. The in-code justification is
backwards. **Fix:** on a reconcile- scan failure, skip `Coverage.record` for
that region (mirror the backfill-failure branch). Distinct resurrection path
from #2.

### B1 [MDL] `upsert` arity crash — SQLite-authority actions and Postgres-cache propagation raise `UndefinedFunctionError`

`write_dispatch.ex:56`, `backfill.ex:83`, `local_outbox/write.ex:243` MDL calls
`Ash.DataLayer.run_upsert/4` and `/5` **directly**, bypassing the public
`Ash.DataLayer.upsert/4` dispatcher (which picks arity via
`function_exported?(dl, :upsert, 4)`). `run_upsert/5` `apply`s `upsert/4`;
**AshSqlite exports only `upsert/3`** → every `upsert? true` action on a
LocalOutbox resource (flagship SQLite local layer) crashes in `local_write`.
`run_upsert/4` `apply`s `upsert/3`; **AshPostgres exports only `upsert/4`** →
`Backfill` propagation into an AshPostgres cache layer crashes on every
read/write. The shipped Ets+Postgres test combo has both arities so the suite
can't see it. Verified: exports (`ash_sqlite/lib/data_layer.ex:1296`,
`ash_postgres/lib/data_layer.ex:3798`), dispatcher
(`ash/lib/ash/data_layer/data_layer.ex:1003-1011`), pinned `apply`
(`run_upsert/5` :1048, `/4` :1021). **Fix:** call `Ash.DataLayer.upsert/4` (the
dispatcher) or replicate its `function_exported?` check in all three call sites.

### B2 [MDL] Attribute-strategy multitenancy makes invalidation completely dead

`write_dispatch.ex:78`, `coverage/invalidation.ex:84` Ash calls the data-layer
`set_tenant` **only for `:context` strategy**
(`ash/lib/ash/query/query.ex:4653`), so for **attribute** multitenancy
`Query.tenant` stays `nil` and reads record coverage under `:__global__`, while
writes invalidate under `changeset.tenant` (the concrete attribute value). The
two partitions never meet: the C3 epoch race-guard never fires, the propagation-
failure safety net is false, and upsert `drop_all` drops nothing. Sharper form
of #3 — for attribute tenancy the invalidation path is structurally inert.
**Fix:** partition the ledger by tenant only when the strategy is `:context`;
add an attribute-tenancy integration test asserting a write drops the covering
entry.

---

## MED

### #9 [cross-repo] HTTP-level 401/403 defeats the M-6 auth-park fix

`ash_remote/lib/ash_remote/error/transport.ex:36` + `local_outbox/flush.ex:234`
`{:http_error, status, _}` normalizes to class `:unknown`; an upstream auth plug
(ash_authentication `require_authenticated`, or a proxy) rejecting an expired
token replies 401/403 at the HTTP layer, so `Flush.classify` hits its
`:transient` catch-all → burns the retry budget and parks `:transient_exhausted`
instead of `:auth` (the exact M-6 failure via the path M-6 didn't cover).
**Fix:** map 401/403 to a `:forbidden`-class error in `Transport.normalize`.

### #10 [ash_remote, SECURITY] Client mints unbounded atoms from server error paths

`ash_remote/lib/ash_remote/error.ex:64` `to_atom` falls back to `String.to_atom`
for every element of the server-controlled `error["path"]` (the server
stringifies all path elements, so the `to_existing_atom` happy path routinely
misses on indices like `"0"`). A malicious/compromised backend exhausts the
client atom table. Same class as R-2/R-8, missed on the error path. **Fix:**
keep path segments as strings, or fall back to `:unknown`.

### #11 [ash_remote] Filter encoder crashes mid-request on unsupported expressions

`ash_remote/lib/ash_remote/data_layer.ex:44` + `encode/filter.ex:56,41`
`can?({:filter_expr, _}) → true` for _all_ expressions, but the encoder raises
for anything outside its 8 operators.
`Ash.Query.filter(RemoteTodo, contains(title, "x"))` raises `ArgumentError`
inside `run_query`; `expr(inserted_at < now())` survives to Jason and dies with
`Protocol.UndefinedError`. The boolean **`false`** filter (produced by a policy
that authorizes nothing) is also unencodable → `filter.ex:41` handles `true` but
not `false` → authorization-dependent crash instead of `[]`. **Fix:** make
`can?({:filter_expr, expr})` pattern-match encodable shapes; short-circuit
`false` to `{:ok, []}`.

### #12 [MDL] `NotLoaded` written as garbage in two unguarded propagation paths

`write_dispatch.ex:157` (propagate) + async flush (`flush.ex:166`/`target.ex`);
root cause `backfill.ex:110` Both call `Backfill.upsert_record`/`upsert_records`
with no `:fields`, so `default_fields` = every attribute. On a
partially-selected update (`action_select` or a remote authority returning only
requested fields), unselected fields are `%Ash.NotLoaded{}` → cast fails
silently (errors added, never checked) and clobbers the cached/remote value with
NULL. `write_through` (`write.ex:156`) and the read-path backfill both guard
this; these two don't. **Fix:** filter to loaded-non-NotLoaded fields ∪ PK.

### #13 [MDL/LocalOutbox] `refresh/3` TOCTOU clobbers a concurrent local write

`local_outbox/api.ex:337` (+ `reconcile_deletes` :461) A user write committing
between the `dirty?` check and `Backfill.upsert_record` gets its local value
overwritten by the stale remote row while its outbox entry still flushes the new
value → the "authoritative" local layer holds the older value than the remote.
Mirror: a row created inside the read window is deleted locally. The LocalOutbox
sibling of the M-3 epoch bug fixed only in ProvenCoverage. **Fix:**
dirty-check + upsert in one co-commit-repo transaction / watermark guard.

### #14 [MDL/LocalOutbox] `write_through` drain races an in-flight flush → target regresses

`local_outbox/write.ex:64` `drain_chain_inline` pushes V1 and destroys entry N
with no coordination with the Oban queue; a worker mid-flush of N then upserts
V1 over the write_through's V2 → local V2, target V1, no outbox entry, silent
divergence. **Fix:** pause the flush queue / per-PK lock spanning
drain+push+local-write, or have the worker re-verify entry existence immediately
before pushing.

### #15 [MDL/LocalOutbox] `write_through` local failure after target push → silent divergence

`local_outbox/write.ex:56` Targets-first-local-last (the M-2 order) has no
compensation: if `local_write` fails after `push_all_targets` succeeded, the
caller is told the write failed, but targets hold V2 with no outbox entry; a
later refresh pulls V2 into the "clean" local row, materializing the "failed"
write. **Fix:** compensate (re-push pre-image) or record the divergence.

### #16 [MDL/LocalOutbox] `discard/1` of a non-create head never kicks the next entry; head-first non-transactional drops

`local_outbox/api.ex:127` (+ create-drop :130, `drop_chain` :513) `discard` of a
non-create just destroys and returns — every other head-resolving verb re-kicks
— so a following `:pending` entry that already ran as `:blocked` sits with no
job (compounded by #4). Also, `discard` of a create and `drop_chain` destroy
**head-first, non-transactionally**, the opposite of `destroy_captured_chain`'s
own desc-order rationale — a mid-drop crash unblocks the tail and re-creates the
discarded row on the target. **Fix:** `kick_next` in the non-create branch;
destroy newest-first inside a co-commit transaction.

### #17 [MDL/LocalOutbox] Resolution verbs have no state guards and are non-idempotent

`local_outbox/api.ex:109-202`, `inject_outbox.ex:186` `retry` on a `:synced`
entry re-pends and double-applies; `force`/`discard` called twice raise (`force`
re-pushes to the target _first_, then raises on the destroy); `force(newer)`
then `retry(older)` inverts per-PK FIFO. In multi-target configs the verbs'
cleanup is per-target but `rebase`'s apply is global → double-applies. **Fix:**
validate `state == :parked` / chain-head, refetch, rescue not-found into
idempotent `:ok`.

### #18 [MDL/LocalOutbox] `discard_local/1` crashes on a remote-read error

`local_outbox/api.ex:159` Matches only `{:ok, nil}`/`{:ok, remote}`;
`Target.read_pk` also returns `{:error, _}` → `CaseClauseError`, precisely when
its entries are parked because the remote is unreachable. The public
`refresh/3`/`hydrate/2` similarly `MatchError` on remote failure
(`api.ex:450,464`). **Fix:** add `{:error, _}` clauses.

### #19 [MDL/LocalOutbox] Tenant dropped on every entry-driven target call

`flush.ex:160,166,184`, `api.ex:159,184`; chain filters `write.ex:70`,
`chain_position`, `kick_next` The enqueue persists `entry.tenant`, but the flush
push, `stale_check`, `force`, and `discard_local` call `Target`/`Backfill` with
no `tenant:` → tenant-aware targets get wrong/no-tenant writes and stale-checks
read the wrong row (`{:ok, nil}` → blind overwrite). The chain-ordering filters
omit tenant while `base_query` includes it → cross-tenant chain interference
when PKs collide. **Fix:** thread `entry.tenant` through all entry-driven calls
and chain filters.

### #20 [MDL] Shell `default_can?` advertises capabilities it can't execute

`data_layer.ex:336,583` For any orchestrator using the `:default` fallback,
`:bulk_create` / `{:query_aggregate,_}` / `:aggregate_filter` intersect true
across Ets+Postgres → Ash calls `bulk_create/3` (undefined →
`UndefinedFunctionError`) or `run_aggregate_query/3` (an _optional_ callback) or
re-opens the `__ash_bindings__` crash ProvenCoverage explicitly guards. **Fix:**
explicit `false` clauses + `function_exported?` guards. (Double-confirmed.)

### #21 [MDL] `ExternalChange` notifier reacts to this node's own writes

`notifiers/external_change.ex:32` Every local Ash notification is routed to
`handle_external_change` with no origin marker, so each local write triggers
`forget!` (epoch bump + physical eviction) that undoes the propagation it just
did. Sub-point: the optional `handle_external_change/2` is called unguarded
(:34) → an orchestrator without it turns every inbound notification into rescued
warn-spam that looks transient. **Fix:** require a transport-replayed marker in
`notification.metadata`; `function_exported?`-guard the call.

### #22 [MDL] No verifier ties write-authority to read-source

`verifiers/validate_layers.ex` `read_order [:l1,:l2]` + `write_order [:l1,:l2]`
compiles but makes the cache authoritative while reads treat l2 as truth → one
propagation failure permanently diverges, and fall-through reads record coverage
over stale data. **Fix:** require `List.last(read_order) == hd(write_order)` for
ProvenCoverage.

### #23 [MDL/ProvenCoverage] Aggregate-fold returns silent nils on cold cache

`proven_coverage.ex:323-347,398` For a `limit`/`offset`/`distinct`/opaque-filter
query with aggregates on a cold cache, the base read misses, `maybe_backfill` is
gated off, then the fold replays the still-limited query against the empty cache
layer → `copy_aggregate_values(row, nil, ...)` leaves every aggregate
`%Ash.NotLoaded{}` — the silent-nil shape the module's docstring says it refuses
to emit. Also occurs transiently after a backfill error/epoch-abort. **Fix:**
run an `ensure_source_aggregates_resolved!`-style check on the fold output; fold
non-recordable queries against the already-fetched base rows.

### #24 [ash_remote] `upsert/3` ignores `keys`; upsert-as-update truncates fields

`ash_remote/lib/ash_remote/data_layer.ex:190,352` Non-PK `upsert_identity`
resolves by PK anyway → mis-resolves and surfaces a collision; the update path
takes `Map.take(attributes, action.accept)`, so replicating a create for a row
whose primary update accepts fewer fields silently converges only those — a
**divergent replica with a success return** (directly affects
LocalOutbox→AshRemote replication). **Fix:** build the resolution filter from
`keys`; bypass `accept` for the action-less backfill path.

### #25 [ash_remote] Query calcs/aggregates decoded uncast

`ash_remote/lib/ash_remote/decoder.ex:61-77` `Map.put`s raw wire values while
attributes and prefetched calcs are cast — a `:date` calc yields a String, a
decimal `:sum` a String, breaking downstream `%Date{}`/`%Decimal{}` matches and
poisoning cache layers. **Fix:** cast via `calc.type`/`agg.type`.

### #26 [ash_remote/realtime] `LifecycleGuard` goes permanently deaf after a Registry restart

`ash_remote/lib/ash_remote/multi_datalayer/lifecycle_guard.ex:85` Registers once
in `init` and never monitors the registry; if the `AshRemote.Realtime`
supervisor (owning the registry) restarts while the sibling guard stays up, the
new registry is empty and every future `:resubscribed`/`:join_denied` is dropped
→ unbounded silent staleness. Its `reconcile` also only `rescue`s, missing
GenServer-timeout **exits** (same class as commit A4). **Fix:** monitor the
registry and re-register on `:DOWN`; `try/catch :error,:exit,:throw`.

### #27 [ash_remote/server] Field-policy-denied field 500s an RPC read

`ash_remote/lib/ash_remote/server/fields.ex:89` A field-policy-denied selected
field returns `%Ash.ForbiddenField{}` (no `Jason.Encoder`); `serialize` passes
it through, `run_action` reports success, then `Jason.encode!` at `router.ex:96`
raises **outside** the rescue → raw 500. **Fix:** map
`%Ash.ForbiddenField{}`/`%Ash.NotSelected{}` to nil in `value/1`/`loaded/1`.

### A2 [MDL/ProvenCoverage] Inbound update notification passes the after-image as `row_before`

`proven_coverage.ex:177` `handle_external_change` funnels _all_ replayed
notifications (updates included) through `forget!`, wiring the record into
`on_write`'s `row_before` slot. For an update that record is the _after_ image,
so `should_drop?(entry, after_image, nil)` evaluates the entry's filter against
the new values — an entry covering `status == :active` is not dropped when the
row flips to `:archived`, leaving a stale row under a live covering entry.
**Fix:** for update notifications call `on_write` with a PK-only unknown
before-image and the concrete after-image.

### A3 [MDL/ProvenCoverage] String-range subsumption uses byte order vs source collation → false hit drops rows

`coverage/interval.ex:165` Ash defines no `BitString` comparable, so
`Interval.compare` on string bounds falls to Kernel byte comparison. A recorded
entry `name > "B"` and a probe `name > "b"`: byte order says `"B"(66) < "b"(98)`
→ the solver proves subsumption → HIT, but a Postgres source under an ICU/locale
collation (`'b' < 'B'`) physically excluded `"B"` from the cache → the hit
serves an incomplete result set, permanently for that filter pair. Overrides the
"interval math clean" conclusion for string range predicates
(equality/`in`/`is_nil` stay safe). **Fix:** refuse `<`/`>` range subsumption on
string/CiString attributes unless bounds are equal, or gate behind a "source
uses C collation" opt.

### A4 [MDL/ProvenCoverage] Composite primary keys crash the miss path

`proven_coverage.ex:767` (reconcile), `:402` (fold stitch) The single-PK guard
exists only on the remainder-split path; `reconcile` runs on every full-miss
`record` and hard-matches a one-element PK (`[pk] = ...primary_key`) →
`MatchError` on the first recordable miss for any composite-PK resource, and no
verifier rejects composite PKs. **Fix:** add a compile-time single-PK verifier
for ProvenCoverage, or use `Map.take(row, primary_key)` like `Divergence`
already does.

### A5 [MDL/ProvenCoverage] Changeset-less notification invalidates `:__global__`, not the tenant

`proven_coverage.ex:192` When a replayed notification carries `data` but no
`changeset` (`notification_tenant(_) → nil`), `forget!` bumps the epoch and
drops entries in the `:__global__` partition — a no-op for the actual tenant,
which keeps serving the pre-change row. Part of the tenant-handling cluster (#3,
#19, B2). **Fix:** derive tenant from the record's multitenancy attribute, or
conservatively sweep all partitions.

### B3 [MDL] `{:error, :no_rollback, term}` unhandled on destroy/propagate/backfill

`write_dispatch.ex:65-73,124-150`, `backfill.ex:24-31` AshPostgres routinely
returns this 3-tuple (constraint violations), and the `Ash.DataLayer.upsert`
callback spec lists it — but `WriteDispatch.destroy`'s outer `case`,
`propagate/5`'s inner `case`, and `Backfill.upsert_records`' reduce all match
only `{:ok,_}`/`{:error,_}` → `CaseClauseError`, incl. after the authoritative
commit (violating the "propagation failure never fails the operation" contract).
**Fix:** normalize `{:error, :no_rollback, reason}` → `{:error, reason}` at each
boundary.

---

## LOW

- **[MDL/LocalOutbox] `rebase/2` "all-or-nothing transaction" is a no-op on
  ash_sqlite.** `local_outbox/api.ex:262` — `Ash.DataLayer.transaction` only
  opens a transaction when `can?(:transact)`, which ash_sqlite hardcodes false;
  a mid-cleanup failure leaves a partially destroyed chain, and the
  `RebaseCleanupError` message ("Nothing was destroyed") is false on the
  flagship stack. Use the co-commit Ecto repo directly.
- **[MDL/ProvenCoverage] `Coverage.insert/2` is the one ETS accessor without an
  `ArgumentError` rescue** (`coverage.ex:56`) → a TableOwner restart mid-record
  crashes an already-succeeded read.
- **[MDL/ProvenCoverage] `dedupe_key` is a bare `phash2`** (`coverage.ex:583`)
  with no disjunct comparison → a collision (birthday estimate ~30% at a full
  10k-entry partition) widens an unrelated entry's `loaded_fields`, serving
  never-backfilled fields as nil. Store/compare the canonical term.
- **[MDL/ProvenCoverage] Check-insert-verify / commit-then-invalidate are not
  crash-safe** — a recorder killed between insert and verify, or a writer killed
  between commit and invalidate, leaves lasting stale coverage. Insert entries
  as inert `pending` and flip active after verify.
- **[MDL/ProvenCoverage] Ledger growth is capped per-tenant only** — unbounded
  across tenants; epoch meta rows never GC'd. Add a global cap / idle-partition
  sweep.
- **[MDL] `Capability.collect/2` skips `simple_expression`**
  (`capability.ex:55`) → an `:unknown` nested only in a simple form escapes the
  probe.
- **[MDL] `RejectMultiNode` reads app env at compile time**
  (`reject_multi_node.ex:18`) — a runtime.exs override can't silence it.
- **[MDL] `Divergence` shadow-read false positives** (`divergence.ex:37`) — not
  epoch-guarded; alarms operators learn to ignore.
- **[MDL] `Supervisor` explicit `resources:` list isn't filtered by
  `multi_datalayer?`** (`supervisor.ex:59`) — a non-MDL resource is grouped
  under the default orchestrator.
- **[MDL] Only `sql_join_aggregate_overrides` is typo-checked**
  (`validate_aggregate_overrides.ex:14`) — `fold_aggregate_overrides`/
  `local_evaluation_overrides` typos silently change evaluation semantics.
- **[MDL/LocalOutbox] SQLite rowid reuse after discarding the max-seq entry**
  collides with Oban's unique-by-`seq` job (inherits stale backoff/attempts).
  Include `write_ref` in the job key or use `AUTOINCREMENT`.
- **[MDL/LocalOutbox] Stale-check treats a missing remote row as "no conflict"**
  (`flush.ex:184`) → an `:update` flush silently resurrects a peer-deleted
  record. For `op: :update` with a non-nil base_image, treat `{:ok, nil}` as a
  conflict.
- **[MDL/LocalOutbox] Stale-check bypass for `:upsert` ops** (`flush.ex:175`,
  `write.ex:286`) — an upsert landing on a diverged remote row silently LWW-
  overwrites even with stale-check on. Doc note at minimum.
- **[MDL/LocalOutbox] `:synced` entries are never pruned** — unbounded outbox
  growth; `status/1` scans all of a record's entries per poll.
- **[MDL/LocalOutbox] `HostResolver` persistent_term cache never invalidated**
  after a hot code reload — a resource added post-boot parks entries
  `:rejected`.
- **[cross-repo] Idempotent remote delete parks as `:rejected`** — a destroy of
  a row already gone remotely returns `not_found` (class `:invalid`) →
  `classify` → `:rejected` instead of succeeding. Treat `not_found` on a destroy
  push as success.
- **[ash_remote] Double `authorization` header** when static + actor token both
  present (`data_layer.ex:389`). Dedupe by name with explicit precedence.
- **[ash_remote] `retry` config applied to non-idempotent write POSTs**
  (`transport/transport.ex:41`) — duplicate rows on timeout. Constrain to
  `:run`.
- **[ash_remote] Composite-PK `[pk] =` crashes remote calcs**
  (`data_layer.ex:314`, `remote_calculation.ex:39,64`).
- **[ash_remote] Sort on a parameterized calculation drops its args**
  (`encode/sort.ex:31`) — server sorts with defaults, silently.
- **[ash_remote] Malformed `{"success":true}` with no `data` crashes**
  `decode_records` (`decoder.ex:26`, `protocol.ex:63`). Normalize/reject.
- **[ash_remote/server] Unauthenticated `GET /manifest.json`** schema disclosure
  (`server/router.ex:64`). Document mounting behind auth / provide a hook.
- **[ash_remote/server] Join-time-snapshot subscriptions with no revocation
  path** (`channel.ex:49`, default `socket id/1 → nil`) — a deactivated user
  keeps receiving rows until they disconnect.
- **[ash_remote/server] Changeset-less mutations on multitenant resources
  broadcast to an unjoinable topic** (`notifier.ex:67`) — notification silently
  lost.
- **[ash_remote/server] Per-subscriber DB refetch amplification** on `:unknown`
  filter eval (`channel.ex:87,143`) — N subscribers × M writes/s.
- **[ash_remote] Stale `connect_params` doc comment**
  (`realtime/connection.ex:170`) contradicts the R-9 fix at :29.
- **[ash_remote/codegen] Aggregates over many-to-many/private relationships** →
  uncompilable resources (`generator.ex:357`).
- **[ash_remote/codegen] `belongs_to` drops the FK's type/nullability**
  (`generator.ex:119,294`) → integer-PK backends get `:uuid` FKs.
- **[ash_remote/codegen] `@known_atoms` omits aggregate kinds**
  (`loader.ex:212`) — raises unless the mix task loaded first.
- **[ash_remote/codegen] Guard's gap reaction only `rescue`s, missing exits**
  (`lifecycle_guard.ex:128`).
- **[ash_remote/codegen] Path traversal via manifest module strings**
  (`ash_remote.gen.ex:81`).
- **[ash_remote/codegen] Non-string `schema_version` raises
  `FunctionClauseError`** (`loader.ex:103`) instead of
  `{:error, {:unsupported_schema_version, _}}`.
- **[ash_remote/codegen] Calc arguments always `allow_nil?: true`**
  (`generator.ex:319`) — required args fail only at the server.
- **[ash_remote/encode] `ref_name/1` silently drops `relationship_path`**
  (`encode/filter.ex:88`) — one capability tweak from a silent unscoped filter.

---

## Recurring root causes

1. **Tenant handling** — raw vs converted vs strategy-dependent, wrong in ≥4
   paths (#3, #19, A5, B2). Fix by deriving one canonical partition key keyed on
   the multitenancy strategy, used identically on read and write.
2. **`Backfill` writing all attributes incl. `%NotLoaded{}`** in the two callers
   that don't pass `:fields` (WriteDispatch propagate, async flush) while the
   other two do (#12; LOW variants). Filter to loaded fields ∪ PK in
   `default_fields`.
3. **Reimplementing framework/protocol dispatch incompletely** — the upsert
   arity (B1), the unguarded optional callbacks (#20, #21), and the state-less
   resolution verbs (#17) all bypass a dispatch/guard Ash or the protocol
   already provides.

---

## Areas verified clean

- Interval/complement math (nil-safe complements, De Morgan, degenerate regions,
  property suites) — **except** string-range subsumption under byte order (A3).
- Epoch seed/bump mechanics, incarnation-on-restart, meta-key non-collision,
  `update_counter` atomicity — **except** crash-safety of the two-step protocol
  (LOW).
- LocalOutbox seq-vs-commit ordering (co-commit row lock serializes same-PK
  writers); chain-position races fail in the safe direction; steady-state Oban
  job dedup.
- The expression/literal safe-encode grammar on the **encode** side (no
  injection); transport error typing; tenant threading for **context** strategy.
- `Delegate`, `ValueMerge`, `SqlPassthrough`, `KillSwitch`, `Migration`, the mix
  tasks, and the DSL verifiers' happy paths.
