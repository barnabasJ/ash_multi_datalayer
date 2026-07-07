# Implementation review: 2026-07-06 second-review fix plan

**Date**: 2026-07-07
**Reviewer**: implementation-fidelity + whole-repo correctness pass (4-agent fan-out
+ hand-verification of every blocker-class finding against source).
**Subject**: the implementation of
[`docs/plans/20260706-second-review-findings-fix-plan.md`](../plans/20260706-second-review-findings-fix-plan.md)
across `ash_multi_datalayer` and the sibling `../ash_remote`.
**Findings source**: [`docs/reviews/20260706-second-review-findings.md`](20260706-second-review-findings.md)
(finding IDs #1–#27, A1–A5, B1–B3).

Verdict tags used below:
- **[VERIFIED]** — reviewer read the source and confirmed the defect end-to-end.
- **[AGENT]** — reported by a review agent, traced but not independently re-confirmed here.

---

## Executive summary

The second-review fix plan is **not ready**. It is only partially implemented,
**entirely uncommitted**, and several of the fixes that did land are inert or
actively regressive against real inputs.

Framing that matters for interpreting the repo state:

- **The committed history is the *first* fix plan** (whole-repo-review findings
  M-1…M-12 / R-1…R-11). That work is done and green: `ash_multi_datalayer`
  267 tests incl. `INTEGRATION=1` (2 excluded: opt-in DB replay properties),
  `ash_remote` 176 tests. It has a handoff doc
  (`docs/tasks/20260706-review-findings-fix-handoff.md`).
- **The *second* plan — this review's subject — exists only as an uncommitted
  working tree**: the `git diff` plus untracked `lib/ash_multi_datalayer/tenant_key.ex`
  and `lib/ash_multi_datalayer/orchestrator/local_outbox/sweeper.ex`
  (and, in `../ash_remote`, uncommitted `lib/` changes). There is no handoff or
  execution record for it.

**The plan's mandatory repro-first discipline was skipped.** The plan makes it a
completion gate that each phase's new tests fail on the unfixed code before the
fix, and that race fixes prove the reviewed interleaving. There are **zero new
test files in either repo** — only ~37 lines of edits to existing MDL tests and
~23 lines of edits to existing ash_remote tests. This is why findings #1, #3
(tenant), #4 (external-change), #5, and the aggregate-override regression all
shipped looking correct: nothing exercises them against real inputs. The green
suites run on the single-tenant SQLite stack, which structurally avoids the
tenant-partition defects.

Do **not** treat this working tree as a landed implementation.

---

## What is sound (credit where due)

- **ProvenCoverage core**: the interval/complement/implication solver (boundary
  logic, nil-safe complements, conservativity), the epoch check-insert-verify
  protocol in `Coverage.record` (incl. widen path and non-resurrecting LRU
  touch), `on_evict`'s batched epoch join, and reconcile scope (`Q∧¬C` only,
  source-half backfill) are correct and match their documented invariants.
- **A2 (dispatch/normalization)**: upsert arity guard mirroring Ash's dispatcher
  in `write_dispatch.ex:163-171`, `backfill.ex:101-109`, `write.ex:254-263`;
  `{:error, :no_rollback, _}` normalized at MDL boundaries; `default_can?`
  tightened (`data_layer.ex:314-317` returns false for `bulk_create`,
  `{:bulk_create,_}`, `aggregate_filter`, `{:query_aggregate,_}`);
  `function_exported?` guard on the optional notifier callback.
- **A6**: `backfill.ex:114-122` `default_fields/2` filters `%Ash.NotLoaded{}`;
  `flush.ex` classifies HTTP 401/403 as `:auth`.
- **#2 / A1 (ProvenCoverage)**: backfill-eviction on `:epoch_moved`
  (`evict_backfilled_rows`) and reconcile-scan-failure-skips-record are
  implemented and sound.
- **ash_remote landed items**: #6 (open-vocab atom safety), #9 (401/403 transport
  taxonomy via `Transport.normalize/1`), #10 (atom-minting error path removed),
  #11 (false/unsupported filter short-circuit + `encodable?` `can?`), #26
  (LifecycleGuard registry monitor/re-register + `try/rescue/catch` for
  `:error`/`:exit`/`:throw`), and the non-string `schema_version` typed error.
- **Oban double-enqueue is a non-issue**: ash_oban workers carry
  `unique: [period: :infinity, states: :incomplete]` with no `keys:` restriction,
  so the sweeper/kick/retry inserts (incl. the new `write_ref` arg) dedupe.

---

## Blocker-class findings

### B1 — [VERIFIED] Private calculations/aggregates are exfiltratable over RPC
- **File**: `../ash_remote/lib/ash_remote/server/fields.ex:133-134`
- **Plan ref**: R1 item 1 / findings #1, #27
- **Defect**: `attribute?`/`relationship?` (lines 132/135) use `Info.public_attribute`/
  `Info.public_relationship`, but `aggregate?`/`calculation?` use the non-public
  `Info.aggregate`/`Info.calculation`, which match `public? false` entities.
  `public_name/2` (line 141) therefore accepts a private calc/aggregate name; it
  is loaded and serialized back.
- **Scenario**: `POST /rpc/run {"resource":"App.User","action":"read","fields":["internal_risk_score"]}`
  where `internal_risk_score` is a `public? false` calculation → the server
  returns its value. Reachable on read/create/update responses and nested
  relationship selections. On a no-authorizer resource it is fully
  unauthenticated.
- **Evidence**:
  ```elixir
  defp aggregate?(resource, name), do: not is_nil(Info.aggregate(resource, name))
  defp calculation?(resource, name), do: not is_nil(Info.calculation(resource, name))
  ```
- **Fix**: switch to `Info.public_aggregate`/`Info.public_calculation`. Public
  calcs/aggregates (the only ones a client should name) keep working.

### B2 — [VERIFIED] Aggregate-filter code injection at codegen time (#7 not fixed)
- **File**: `../ash_remote/lib/ash_remote/gen/generator.ex:374-375`
- **Plan ref**: R2 item 3 (CRITICAL in plan)
- **Defect**: `aggregate_block/2` splices `field.aggregate_filter` raw into
  `"\n      filter expr(#{field.aggregate_filter})"` with no `AshRemote.Expression.safe?`
  gate. `reproducible_aggregate?/1` (line 361) only checks a relationship is
  present. The calc path (line ~338) *does* gate on `safe?`; the aggregate path
  does not. Loader passes `field["aggregate_filter"]` through unvalidated.
- **Scenario**: a manifest with `aggregate_filter: "eval_something() or x"` on a
  relationship-bearing aggregate produces `filter expr(<injection>)`, executing
  arbitrary code at `mix ash_remote.gen`. The manifest is server-controlled.
- **Evidence**:
  ```elixir
  filter_line =
    if field.aggregate_filter, do: "\n      filter expr(#{field.aggregate_filter})", else: ""
  ```

### B3 — [VERIFIED] `tenant_from_filter/2` is dead code — attribute-tenancy invalidation still inert
- **File**: `lib/ash_multi_datalayer/tenant_key.ex:44-73`
- **Plan ref**: A1 item 1 / findings B2, #3, A5
- **Defect**: derives the attribute-tenancy read partition by regexing
  `inspect(filter, limit: :infinity)` for `attr...value: X`. An `%Ash.Filter{}`
  inspects as `#Ash.Filter<org_id == "acme">` — the substring `value:` never
  appears — so the function always returns `nil`. Reads record coverage under
  `:__global__` while writes invalidate under `TenantKey.changeset` →
  `Map.get(record, attr)` (the concrete value). The partitions never meet.
- **Scenario**: attribute-strategy multitenancy, tenantless read
  `filter(org_id == "acme")` → coverage recorded under `:__global__`; every write
  for `"acme"` bumps the `"acme"` epoch and evicts physical rows there; the
  `:__global__` entry survives forever → next read is a permanent stale/missing
  cache hit. Exactly finding B2, unresolved.
- **Additional unsoundness even if the regex matched**: returns integer/uuid/atom
  tenants as *strings* (`"42"` ≠ `42`) → mismatch vs the typed write-side key;
  `[^,}\]]+` truncates `in` lists; greedy match picks the wrong predicate in
  multi-predicate/`or` filters; unanchored attr substring collides
  (`org` matches `organization_id`).
- **Plan divergence**: plan + accepted review item S1 specified
  `Ash.Resource.Info.multitenancy_attribute/1` + `Map.get(record, attr)` on read
  rows, not filter-inspect parsing. Correct fix: structural walk of the filter
  AST for an `Eq` on the tenant attribute, or extraction from returned rows.

### B4 — [VERIFIED] ExternalChange origin marker matches no real notification → realtime invalidation dead
- **File**: `lib/ash_multi_datalayer/notifiers/external_change.ex:72-78`
  vs producer `../ash_remote/lib/ash_remote/realtime/inbound.ex:156`
- **Plan ref**: A7 item 1 / finding #21
- **Defect**: `replayed_external?/1` matches either all-string
  (`%{"ash_remote" => %{"origin" => _}}`) or all-atom
  (`%{ash_remote: %{origin: _}}`) metadata. The producer emits
  `Map.put(user_meta, "ash_remote", %{origin: :remote, id: ..., occurred_at: ...})`
  — **string outer key, atom inner key** — which matches neither clause, so it
  falls to `_ -> false` and the notification is dropped.
- **Scenario**: a peer writes a row; the replayed external notification is
  dropped → `handle_external_change` never runs → coverage/local-refresh never
  happens → permanent silent staleness on every externally-replayed change. #21
  (react only to external writes) was over-corrected into reacting to nothing.
- **Evidence** (producer): `Map.put(user_meta, "ash_remote", %{origin: :remote, ...})`.
  The two adapted tests use synthetic all-string
  (`external_change_exit_test.exs`) and all-atom (`local_outbox_test.exs`) shapes
  — each passes one clause; the real mixed shape passes none.

### B5 — [VERIFIED] `validate_aggregate_overrides` compile regression breaks legitimate configs
- **File**: `lib/ash_multi_datalayer/verifiers/validate_aggregate_overrides.ex:30`
- **Plan ref**: A7 item 6 (extend typo checking) — over-reached
- **Defect**: the loop validates `local_evaluation_overrides` against
  `Ash.Resource.Info.aggregates/1` names, but that option holds **calculation**
  names (`data_layer.ex:149` doc "Calculation names…"; consumed at
  `value_merge.ex:57` as `calculation.name not in overrides`).
- **Scenario**: any resource declaring `local_evaluation_overrides [:overdue?]`
  (a calculation) fails compilation: "`[:overdue?]` … is not an aggregate on this
  resource." The example avoids it, so suites stay green.
- **Fix**: validate `local_evaluation_overrides` against calculation names, keep
  the two aggregate-override options against aggregate names.

### B6 — [VERIFIED] `remote_matches_payload?` / stale-check dead for timestamped resources (#5 inert)
- **File**: `lib/ash_multi_datalayer/orchestrator/local_outbox/flush.ex:231-234`
- **Plan ref**: A5 item 1 / finding #5
- **Defect**: compares `Snapshot.dump(host, remote)` (dump-to-embedded values:
  `%DateTime{}`/`%Decimal{}` structs) against `entry.payload` (stored in a `:map`
  attribute, read back through SQLite's JSON round-trip → ISO strings / plain
  numbers) with no `json_scalar` normalization — although the field-level compare
  just below (lines 210-217) applies exactly that normalization for this reason.
- **Scenario**: with `conflict_detection: {:stale_check, :updated_at}`, a flush
  pushes the update to the target, the worker dies before committing `:synced`,
  Oban retries; the remote now equals the payload but `%DateTime{}` ≠
  `"2026-…"` → fast path fails → base-image compare parks the fully-succeeded
  write as a false `:conflict`, blocking the PK chain. Closes only for
  string/integer-only resources.

### B7 — [VERIFIED] #17 resolution-verb guard inverted for `:synced` entries
- **File**: `lib/ash_multi_datalayer/orchestrator/local_outbox/api.ex:603-621`
- **Plan ref**: A5 item 9 / finding #17
- **Defect**: `ensure_resolvable_head/1`'s `cond` returns `:ok` for
  `entry.state == :synced` (falls into the `with` body), so retry (`:111`),
  discard (`:131`), force (`:191`), rebase (`:238`) all proceed on synced
  entries. No re-fetch before applying; no idempotent conversion of
  not-found/stale destroy.
- **Scenario**: `retry(entry)` on a stale handle to a now-synced entry → re-pends
  → `Enqueue.flush` → the already-applied write is pushed again (destroy
  re-deletes a re-created row; per-PK FIFO can invert). `force` on a synced entry
  re-pushes then destroys.
- **Evidence**:
  ```elixir
  cond do
    entry.state == :synced -> :ok            # <- falls INTO the with body
    entry.state != :parked -> {:error, :not_parked}
    ...
  end
  ```

---

## High-severity findings

### H1 — [AGENT] Bundled remote-calculation fetch runs unauthenticated (#8 not implemented)
- **File**: `../ash_remote/lib/ash_remote/data_layer.ex:320,335`;
  `remote_calculation.ex:68-84`
- **Plan ref**: R3 item 1
- **Defect**: `fetch_remote_calculations/4` takes only `tenant` (no actor/context)
  and its request passes no headers (`request(cfg, :run, body)` — defaults `[]`),
  vs the authenticated read path `request(cfg, :run, body, request_headers(query.context))`.
- **Scenario**: `Ash.load!(records, :remote_calc, actor: user)` on cache-layer
  rows → the bundle request carries no Bearer token → backend denies the
  legitimate user or returns unauthorized values.

### H2 — [AGENT] Non-PK upsert identity + accept-list truncation (#24 not implemented)
- **File**: `../ash_remote/lib/ash_remote/data_layer.ex:198,243-247,367`
- **Plan ref**: R3 item 4
- **Defect**: `upsert/3` ignores its `keys` arg (`def upsert(resource, changeset, _keys)`);
  `remote_pk_row/2` resolves solely by primary key. The update path's `input/1`
  still `Map.take(attributes, accepted_keys)` where `accepted_keys = action.accept`,
  so a replicated write with more fields than the update action accepts converges
  only those fields and returns success.
- **Scenario**: a resource with a non-PK `upsert_identity` mis-resolves and
  surfaces a collision; a LocalOutbox→AshRemote replicated write produces a
  divergent replica with a success return.

### H3 — [VERIFIED] `refresh/3` TOCTOU vs the co-committed local write (#13 not implemented)
- **File**: `lib/ash_multi_datalayer/orchestrator/local_outbox/api.ex:341-372,477-492`
- **Plan ref**: A5 item 4
- **Defect**: `dirty?` check and `Backfill.upsert_record`/`reconcile_deletes`
  remain separate, non-transactional steps; no co-commit `repo.transaction` or
  watermark guard was added. `reconcile_deletes`'s local read still hard-matches
  `{:ok, local_rows} =` (the #18-sibling `MatchError` on error).
- **Scenario**: a user write commits between the dirty-check and the upsert → the
  stale remote row overwrites the fresh local value (or a just-created row is
  deleted) while the pending entry later flushes the user's value to the remote →
  the authoritative local layer shows an older state than the remote (lost update
  on the authority).

### H4 — [VERIFIED] `write_through` drain race and post-target-push divergence (#14, #15 not implemented)
- **File**: `lib/ash_multi_datalayer/orchestrator/local_outbox/write.ex:52-98`
- **Plan ref**: A5 items 5, 6
- **Defect**: `drain_chain_inline` reads-and-pushes with no per-PK lock, queue
  pause, or worker re-check of entry existence before push (#14). After
  `push_all_targets` succeeds, a `local_write` failure just returns the error —
  no pre-image compensation, no divergence record (#15).
- **Scenario (#14)**: an in-flight Oban worker upserts V1 over write_through's V2
  after the drain destroyed the entry. **(#15)**: targets hold V2, caller told
  "failed", a later refresh materializes the "failed" write.

### H5 — [VERIFIED / AGENT] Systemic LocalOutbox tenant model: `nil` = "IS NULL" vs "unscoped"
- **File**: `lib/ash_multi_datalayer/orchestrator/local_outbox/api.ex:559-566`
  (`base_query`/`tenant_filter`), `:435-441` (`boot_hydrate`), `:308`
  (`resume_sync`), `:496-514` (`dirty?`/`outbox_nonempty?`)
- **Plan ref**: A5 item 3 / finding #19 (target-call half)
- **Defect**: `tenant \\ nil` is translated into `filter(is_nil(tenant))`, not
  "unscoped". But every entry for a multitenant host stores a stringified tenant
  (`write.ex:273`). `boot_hydrate/1` calls `hydrate/refresh` with no tenant.
- **Scenario**: on a multitenant LocalOutbox host (permitted for ETS/Postgres
  local layers), boot hydration with pending `tenant: "t1"` entries:
  `outbox_nonempty?(resource, nil)` sees only `is_nil(tenant)` rows → reports
  empty → `refresh(:all, nil)` bypasses the dirty-chain rule → pending local
  updates overwritten with stale remote state and pending local creates deleted;
  entries later flush their snapshots → silent local/remote divergence.
  `resume_sync/1` only kicks the nil backlog (60s sweeper latency); `status/1`
  can report `:synced` while entries are pending. Single-tenant SQLite avoids all
  of this — hence green suites.

---

## Medium-severity findings

### M1 — [VERIFIED] `{:ok, {:upsert_skipped, query, callback}}` crashes with `BadMapError`
- **File**: `lib/ash_multi_datalayer/orchestrator/local_outbox/write.ex:213-240`
  (via `Snapshot.record_pk`); also `write_dispatch.ex:82` + `tenant_key.ex:16,33-39`
- **Defect**: ash_sqlite/ash_postgres return `{:ok, {:upsert_skipped, ...}}` for
  condition-skipped upserts (Ash core expects the data layer to surface it).
  `WriteDispatch` handles it, but `LocalOutbox.Write.async_run` passes the tuple
  as `record` to `Snapshot.record_pk` → `Map.get({:upsert_skipped, ...}, pk)` →
  `BadMapError` inside `repo.transaction`. Same crash for attribute-multitenant
  ProvenCoverage resources: `TenantKey.changeset(resource, changeset, {:upsert_skipped, ...})`
  → `attribute_value` → `Map.get(tuple, attr)` → `BadMapError` after the
  authoritative write already ran.
- **Scenario**: any upsert with an `upsert_condition` that skips.

### M2 — [AGENT] External-change invalidation for `:context` tenancy uses the raw metadata tenant
- **File**: `lib/ash_multi_datalayer/tenant_key.ex:25` (`metadata_tenant`) via
  `proven_coverage.ex:198-200`
- **Defect**: read-side coverage partitions and write-side `changeset.to_tenant`
  both use the converted (`to_tenant`) tenant, but `record.__metadata__.tenant`
  is the *raw* tenant. `notification_tenant/2`'s changeset-less clause uses
  `TenantKey.record` → raw metadata tenant.
- **Scenario**: context multitenancy where callers pass a struct/integer tenant
  (`%Org{id: 1}` → `"org_1"`): coverage lives under `"org_1"`; a replayed
  external notification calls `forget!(..., tenant: %Org{}|1)` → epoch bump,
  ledger drop, physical eviction land in the wrong partition → the `"org_1"`
  entry keeps serving the pre-change row indefinitely (the notification was the
  only invalidation signal). Same raw-vs-string mismatch disables the
  dirty-chain check in `Api.handle_external_change`.

### M3 — [VERIFIED] External update notification passes the after-image as `row_before` (A2 not fixed)
- **File**: `lib/ash_multi_datalayer/orchestrator/proven_coverage.ex:172-183`
  + `ash_multi_datalayer.ex:53-61` (`forget_probe`)
- **Defect**: external update notifications route the full after-image record to
  `forget!`, whose `forget_probe(resource, %resource{} = record) -> record` passes
  it verbatim as `row_before` to `Invalidation.on_write(resource, tenant, record, nil)`.
  A PK-only unknown before-image was required (and `forget_probe` already builds
  one for a PK map).
- **Scenario**: a row flips `status: :active → :archived`; the notification's
  `data` is the archived after-image; an entry covering `status == :active` is
  evaluated against `:archived` → not dropped → the stale `:active` cached row
  survives under a live covering entry. One-line fix (`Map.take(record, primary_key)`)
  not taken.

### M4 — [AGENT] `discard_local/1` destroys a freshly re-read chain (M-1-class) and skips the head guard
- **File**: `lib/ash_multi_datalayer/orchestrator/local_outbox/api.ex:160-186,530-537`
- **Defect**: `rebase/2` was fixed to capture the chain *before* applying;
  `discard_local/1` still upserts the remote row then calls `drop_chain(entry)`,
  which re-reads `record_chain` at destroy time. It also lacks
  `ensure_resolvable_head`, and its remote-gone branch builds `backfill_opts(host)`
  without the entry's tenant.
- **Scenario**: an ordinary `Write.run` on the same record lands between the
  local upsert and `drop_chain` → the new `:pending` entry is destroyed → the
  user's write is durable locally but its replication entry is gone → silent
  divergence (no park, no error).

### M5 — [VERIFIED] `refresh` / delete reconciliation not atomic with the dirty check
- **File**: `lib/ash_multi_datalayer/orchestrator/local_outbox/api.ex:341-372,477-492`
- **Note**: overlaps H3; called out separately because the plan (A5 item 4)
  explicitly required the *real co-commit* `repo.transaction` (not
  `Ash.DataLayer.transaction`, which is a no-op on AshSqlite) or a proven
  watermark guard. Neither is present on the refresh path.

### M6 — [AGENT] Destroy-flush of an already-gone row parks as `:rejected`
- **File**: `lib/ash_multi_datalayer/backfill.ex:86-109` (`destroy_record/4`);
  `flush.ex` `classify`
- **Plan ref**: A5 item 11
- **Defect**: `destroy_record` documents "already absent is a success" but returns
  the layer's error (`%Ash.Error.Changes.StaleRecord{}` on zero-row deletes; a
  NotFound/Invalid-class error from remote layers). Nothing maps "absent" → `:ok`.
- **Scenario**: a `:destroy` flush succeeds but the worker crashes before
  committing `:synced`; the retry's destroy fails (row gone) →
  `classify(%{class: :invalid})` → `:rejected` → the entry parks and blocks the
  PK chain, demanding operator `discard/1` for a destroy that already took effect.

### M7 — [VERIFIED] Query calculations/aggregates decoded uncast (#25 not implemented)
- **File**: `../ash_remote/lib/ash_remote/decoder.ex:61-77`
- **Plan ref**: R3 item 5
- **Defect**: `decoder.ex` is untouched. `place/4` for `{:calculation, calc}` /
  `{:aggregate, agg}` `Map.put`s the raw wire value; `cast_calculation/3` is
  wired only to the remote-calc-meta / bundle paths, not the ordinary read plan
  targets.
- **Scenario**: a `:date` query calc yields a String, a decimal `:sum` yields a
  String → downstream `%Date{}`/`%Decimal{}` matches break and cache layers are
  poisoned.

### M8 — [AGENT] Changeset-less multitenant broadcast is unjoinable (R4 item 3 not done)
- **File**: `../ash_remote/lib/ash_remote/server/notifier.ex:67`
- **Defect**: `tenant = notification.changeset && notification.changeset.to_tenant`
  → a changeset-less mutation yields `tenant: nil` → `Topics.topic(source, nil)`
  publishes to a topic no multitenant subscriber joined → notification lost.

### M9 — [AGENT] `discard`/`drop_chain` not inside the co-commit transaction (#16 partial)
- **File**: `lib/ash_multi_datalayer/orchestrator/local_outbox/api.ex:130-152,531-536`
- **Defect**: `discard` of a non-create head now kicks next and create-discard/
  `drop_chain` destroy newest-first, but neither runs inside the co-commit
  `repo.transaction` the plan requires (only `destroy_captured_chain` got
  `transaction!`). A mid-drop crash still leaves a partially destroyed chain
  (newest-first fails in the safer direction, but the atomicity claim is unmet).

### M10 — [AGENT] `hydrate/2` wraps a possibly-`{:error, _}` refresh in `{:ok, ...}`
- **File**: `lib/ash_multi_datalayer/orchestrator/local_outbox/api.ex:392-399`
- **Defect**: `{:ok, refresh(host_resource, :all, tenant)}` — since refresh can now
  return `{:error, reason}`, hydrate returns the malformed `{:ok, {:error, reason}}`
  (spec: `{:ok, map} | {:error, :outbox_not_empty}`).

### M11 — [AGENT] Client decoder crashes on `nil` / single-object read responses
- **File**: `../ash_remote/lib/ash_remote/decoder.ex:26-31` (from `data_layer.ex:132`)
- **Defect**: `decode_records/3` has only `%{"results" => ...}` and `is_list`
  clauses. `Protocol.parse_run` returns `{:ok, nil}` for `%{"success" => true}` /
  `data: null`, and the `get?` read branch returns a bare map or `nil`.
- **Scenario**: a `get? true` primary read (client always targets the primary
  read) or a `data: null` response → `decode_records(nil, ...)` →
  `FunctionClauseError` out of `run_query/2` (no rescue). A malformed/malicious
  server response crashes the caller rather than degrading.

---

## Low-severity findings

- **L1 [VERIFIED]** — `proven_coverage.ex:406-420` (`add_aggregates_via_layer`,
  and `pk_merge` ~:598): `[pk] = Ash.Resource.Info.primary_key(resource)` still
  crashes for composite-PK resources with relationship aggregates (A4 fixed only
  in reconcile/scan paths). Loud crash on a legitimate query.
- **L2 [AGENT]** — `proven_coverage.ex:331-433` (#23): no aggregate-fold
  post-check; `copy_aggregate_values(row, nil, _aggs) -> row` leaves
  `%Ash.NotLoaded{}` on a cold-cache fold; non-recordable (limit/offset/distinct)
  queries aren't folded against fetched base rows.
  **Reproduced live**: `example/todo_client/test/todo_client/live_test.exs:92`
  fails ~70% of runs — `todo_count == %Ash.NotLoaded{}` instead of `2`.
- **L3 [AGENT]** — `write.ex:55-59`: `write_through`'s inline drain keys on
  `changeset.data`'s PK (nil for creates), so a pending chain for a re-created
  client-generated PK isn't drained → recreated row later deleted by the stale
  `:destroy` flush. Also `TenantKey.changeset(resource, changeset, changeset.data)`
  yields nil tenant for attribute-tenancy creates (`attribute_value` reads
  `Map.get(%Ash.Changeset{}, attr)`, always nil — should read
  `changeset.attributes`).
- **L4 [AGENT]** — `interval.ex` untouched (A3 / finding A3): string/CiString
  range subsumption still byte-ordered; `name > "B"` falsely subsumes `name > "b"`
  under ICU collation → rows silently dropped.
- **L5 [AGENT]** — `sweeper.ex:60-62`: `name: {:global, {__MODULE__, sorted}}` — a
  second node returns `{:error, {:already_started, pid}}` and fails the MDL
  supervisor boot. Acceptable only if `RejectMultiNode` hard-fails multi-node;
  A7 item 4 (its compile-time config lookup) was not addressed.
- **L6 [AGENT]** — `../ash_remote` codegen LOWs unaddressed: no identifier
  validation/sanitization; path traversal still possible via
  `Path.join(output, Macro.underscore(module) <> ".ex")` in `ash_remote.gen.ex`;
  calc arg `allow_nil?: true` hardcoded; belongs_to FK type/nullability dropped;
  `@known_atoms` omits aggregate kinds; aggregates over many-to-many/private not
  rejected.
- **L7 [AGENT]** — `../ash_remote` data-layer LOWs: possible duplicate
  `authorization` header (`transport.headers ++ extra_headers` — static + actor
  token both emitted); `retry` applied to non-idempotent write POSTs;
  composite-PK `[pk] =` crashes in `data_layer.ex:322`,
  `remote_calculation.ex:46,71`; `ref_name/1` drops `relationship_path`
  (`encode/filter.ex:96`); sort on a parameterized calc drops args.
- **L8 [AGENT]** — no explicit `authorize?: true` in the RPC server dispatch
  (`server.ex:349-411`); a domain configured `authorize :when_requested` runs
  anonymous RPC unauthorized.
- **L9 [AGENT]** — destroy notifications whose read filter isn't in-memory-decidable
  are dropped (`server/channel.ex:140-141`), stranding subscriber caches until an
  unrelated resubscribe/gap event; intentional for security but a documented
  staleness class the LifecycleGuard must cover.
- **L10 [VERIFIED]** — doc/code contradictions introduced by this work:
  `write.ex:230-233` comment asserts "there is no background sweeper" while
  `local_outbox.ex:222-229` starts one; `backfill.ex` moduledoc/@doc claim
  `default_fields` writes "ALL resource attributes — including `%Ash.NotLoaded{}`"
  while `default_fields/2` now filters NotLoaded out.
- **L11 [AGENT]** — `write_dispatch.ex:162` / `write.ex:208,314`:
  `{:error, :no_rollback, reason}` normalized to `{:error, reason}`, discarding
  the layer's no-rollback signal (Ash then rolls back a transaction the layer
  said to preserve). Narrow impact; contract deviation.

---

## Test / gate evidence

- `ash_multi_datalayer`: `INTEGRATION=1 mix test` → **267 passed** (7 properties,
  260 tests), 2 excluded (opt-in DB replay properties).
- `ash_remote`: `mix test` → **176 passed** (2 doctests).
- `ash_multi_datalayer/example/todo_client`: 20 tests, but
  `test/todo_client/live_test.exs:92` **flakes ~70%** (`todo_count ==
  %Ash.NotLoaded{}`), see L2.
- `ash_multi_datalayer/example/todo_server`: could not run — ports held by
  leftover demo beam processes from a prior session (left untouched).
- `../ash_remote/example/todo_server`: boots with
  `realtime broadcast … no :pubsub_server configured for TodoServer.Endpoint`.
- **New test files: zero in either repo.** The plan's repro-first gate
  ("a phase is not complete until its new tests fail on the unfixed code for the
  stated reason") and Final gate 5 (tenant strategy tests) are unmet. This is why
  B1, B3, B4, B5, B6 shipped looking correct.

---

## Recommended fix order

1. Security holes: **B1** (fields public gate), **B2** (aggregate-filter injection).
2. Tenant model: **B3** + **H5** + **M2** — replace filter-inspect parsing and the
   nil/raw/`to_tenant`/stringified mix with one canonical function that maps any
   tenant representation to the single partition string, used by every path.
3. **B4** (ExternalChange marker), **B5** (compile regression), **B6** (stale-check
   normalization), **B7** (#17 synced guard).
4. Build the A0/R0 repro harness the plan mandates — every race fix must prove the
   reviewed interleaving. This is the control that would have caught B1/B3/B4/B6
   before they landed.
5. Then the remaining HIGH (H1–H4) and MED items.
