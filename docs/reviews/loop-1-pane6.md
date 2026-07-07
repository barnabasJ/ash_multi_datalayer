# Loop 1, Pane 6 — Source-verified review of `docs/tasks/20260707-second-review-fixes/`

Reviewer verified every load-bearing defect claim and every file:line reference
against the actual current source in `ash_multi_datalayer` (MDL) and
`/home/joba/sandbox/ash_remote` (ash_remote). 47 task files reviewed (00-index +
46 task/deferred files). ~70 source file:line refs spot-checked.

**Overall**: the tracker is in strong shape. Every blocker/high defect claim
spot-verified as REAL in source (B1–B7, H1–H5, M1–M11, P1–P6, L1–L13). The
Cat A / Cat B fixed-in-tree assertions all check out against the uncommitted
working tree. The B1 `%Ash.NotSelected{}` sentinel correction is confirmed
(`grep -r NotSelected deps/ash/lib/` is empty; only `not_loaded.ex` and
`forbidden_field.ex` exist). The B3 "always returns nil" claim is confirmed
against the Ash `Filter` Inspect impl (`filter.ex:5110-5124` renders
`#Ash.Filter<expr_doc>`, so the regex hunting for `value:` in
`tenant_key.ex:59` never matches). Cross-task consistency, the B3-lead tenant
unit, and the M3/L4 repro-20 split are all internally consistent.

Findings below are the actionable items found — none rise to HIGH.

---

## MEDIUM

### M1 — P6/H5 dependency claim is unfounded (P6 sequencing note)

**File**: `p6-lost-kick-recovery.md` (Done when, multitenant sweep bullet)

**Claim under review**: "the sweeper's unscoped read must actually see
tenant-scoped entries (ties into H5)" and "If P6 is worked _before_ H5, it
fails on the current H5 defect."

**What the source shows**: The sweeper (`sweeper.ex:38-50`) reads ALL pending
entries with **no tenant filter** — it builds its own query directly
(`Ash.Query.for_read(:read, …)` + `filter(state == :pending)`), and does NOT
call `pending/2`, `base_query/3`, or `tenant_filter/2` (the H5-affected
functions at `api.ex:559-566` that translate `nil` → `is_nil(tenant)`). The
sweeper then calls `Flush.chain_position/3` (`flush.ex:74-92`), which filters
via `Flush.tenant_filter/2` (`flush.ex:157-158`) using **`entry.tenant`** — the
entry's actual stringified tenant (e.g. `"t1"`), never `nil` for a
tenant-scoped entry. The outbox resource stores `tenant` as a regular attribute
(`write.ex:282`), not via the multitenancy DSL, so an unscoped `Ash.read!`
returns all entries across all tenants.

**Conclusion**: The sweeper already sees tenant-scoped entries on the current
code, regardless of H5. The claim that the multitenant sweep repro "fails on
the current H5 defect" if P6 is worked before H5 is wrong — that repro would
**PASS** on current code. An implementer following the sequencing note would
expect a failing repro and find a passing one, causing confusion. The
"retained passing regression" framing is also based on a false premise (it was
never failing on H5). The task's separate sweeper-specific failing repro
(stranded head) is unaffected and remains a valid fail-first anchor.

**Recommendation**: Remove or correct the H5-dependency claim. The multitenant
sweep repro is a valid *retained passing* regression on current code (the
sweeper reads unscoped), not an H5-dependent fail-first repro.

---

## LOW

### L1 — B4 header `Files:` line range is stale ( misses clause 3 )

**File**: `b4-external-change-origin-marker-mismatch.md` (line 12 header)

The `Files:` header says `external_change.ex:72-78`, but the body correctly
says `72-80` (line 17). The three positive clauses of `replayed_external?/1`
span lines **72-80** in `external_change.ex` (clause 1: 72-74, clause 2:
76-78, clause 3: 80). The header range 72-78 omits clause 3 (the
`external?: true` clause at line 80) — the very clause the task's "decide each
of the three clauses explicitly" instruction targets. The body corrects it, but
the header is stale.

### L2 — H2 `accepted_keys` description says "public" but code uses all attributes

**File**: `h2-non-pk-upsert-identity-accept-truncation.md` (line 27, scope note)

The task says `accepted_keys/1` "falls back to **all public attribute names**"
but `data_layer.ex:370` uses `Ash.Resource.Info.attributes()` (ALL attributes,
including `public? false` ones), not `Ash.Resource.Info.public_attributes/1`.
This doesn't change the defect's logic (truncation only bites when
`action.accept` is explicitly set — the fallback is the safe case), but the
description is inaccurate. An implementer reading "public attribute names"
might assume private attributes are excluded from the fallback.

### L3 — H3 current-behavior description is inaccurate (helpers raise, not return `{:error, _}`)

**File**: `h3-refresh-toctou.md` (Done when, `refresh/3` propagation bullet)

The task says "`api.ex:341-371` currently drops helper returns straight into
the `deleted` field" — implying `refresh/3` can currently produce
`%{deleted: {:error, reason}}`. But on the current code:
- `delete_local_pk/3` at `api.ex:387` **raises** on `{:error, reason}`
  (`raise "local read failed during refresh delete reconciliation"`)
- `reconcile_deletes/5` at `api.ex:480` does a hard `{:ok, local_rows} =`
  match (raises `MatchError` on `{:error, _}`)

Neither helper currently **returns** `{:error, _}` into `deleted` — the
`deleted` field is always an integer or a raise. The forward-looking
instruction ("make `refresh/3` return `{:error, reason}` — NOT a successful
`%{deleted: {:error, reason}}` map") is a sound guard against a partial fix,
but the parenthetical describing current behavior is wrong. An implementer
might waste time looking for a `%{deleted, {:error, _}}` shape that doesn't
exist yet.

### L4 — L12 item 1 wrong arity and off-by-one line

**File**: `l12-mdl-misc-lows.md` (item 1, line 15)

The task says "`Coverage.insert/2`" but the actual function is `insert/3`
(`def insert(resource, tenant, entry)` at `coverage.ex:55`). The task says
`coverage.ex:56` but the `:ets.insert` call (the line lacking the rescue) is at
**line 57**; line 56 is `table = TableOwner.table_name(resource)`. The defect
(no `ArgumentError` rescue, unlike every other ETS accessor in the module) is
correct and verified.

### L5 — L12 item 2 off-by-one line

**File**: `l12-mdl-misc-lows.md` (item 2, line 18)

The task says `coverage.ex:583` but the `:erlang.phash2()` call is at **line
582**; line 583 is `end`. The defect (bare `phash2` with no disjunct structural
comparison — a collision widens an unrelated entry's `loaded_fields`) is
correct and verified against `do_record/5` at `coverage.ex:371` which matches
entries by `fingerprint` (the phash2) alone.

### L6 — B6 `remote_matches_payload?` line range off-by-one

**File**: `b6-stale-check-json-normalization.md` (line 13 header)

The header says `flush.ex:231-234` but `remote_matches_payload?/3` spans
**231-235** (line 235 is `end`). The load-bearing defect line (234:
`Snapshot.dump(host, remote) == entry.payload` with no `json_scalar`
normalization) is correctly identified. The "cf. correct normalization at
210-217" reference is accurate.

### L7 — M6 acceptance criterion may not cover remote `NotFound` (only `StaleRecord`)

**File**: `m6-destroy-flush-already-gone-parks.md` (Done when)

The defect description names two error classes: `%Ash.Error.Changes.StaleRecord{}`
on zero-row deletes (SQLite/Postgres local layer) **and** a
NotFound/Invalid-class error from remote layers. The fix instruction says "Map
'row already absent' (StaleRecord on zero-row delete, remote NotFound) to
`:ok`." But the single AC repro — "destroy flush retried after the row is
already gone marks `:synced`" — does not specify which error class it tests.
Since the MDL test suite runs on SQLite, the repro would naturally exercise
`StaleRecord` only. A fix that maps `StaleRecord` → `:ok` but leaves remote
`NotFound` parking as `:rejected` would satisfy the AC while the remote-layer
half of the defect stays open. **Recommendation**: add an explicit assertion
(or second repro) that a remote-layer NotFound-class error on a retried
destroy also marks `:synced`.

---

## INFO

### I1 — M9 "verify `transaction!`" step is already satisfied

**File**: `m9-discard-drop-chain-not-transactional.md` (Rebase cleanup paragraph)

The task says: "Verify which transaction `destroy_captured_chain`'s
`transaction!` actually is — if it is `Ash.DataLayer.transaction` it is a
no-op on AshSqlite and rebase cleanup has the same defect; it must use the
real co-commit Ecto `repo.transaction`." But `transaction!/2` at
`api.ex:623-627` **already** uses the real Ecto `repo.transaction`:

```elixir
defp transaction!(outbox, fun) do
  repo = Module.concat(Ash.DataLayer.data_layer(outbox), Info).repo(outbox, :mutate)
  {:ok, _} = repo.transaction(fn -> fun.() end)
  :ok
end
```

The verification would immediately pass — `destroy_captured_chain` already uses
the correct transaction kind. The actual M9 work is wrapping `drop_chain/1`
(`api.ex:530-537`) and the create-discard branch of `discard/1`
(`api.ex:137-140`) in `transaction!`, not fixing `destroy_captured_chain`. Not
a defect in the task (the instruction is "verify and fix if needed"), but the
implementer can short-circuit the verify step by reading `transaction!/2`.

---

## What was verified and found CORRECT (no action needed)

Spot-verified as accurate against source (non-exhaustive):

- **B1**: `fields.ex:133-134` use `Info.aggregate`/`Info.calculation` (non-public);
  `fields.ex:97-102` map `ForbiddenField`/`NotLoaded` to nil (#27 fix in-tree);
  `%Ash.NotSelected{}` does not exist in `deps/ash/lib/`.
- **B2**: `generator.ex:374-375` splice raw `aggregate_filter`; line 361
  `reproducible_aggregate?/1` checks only relationship; line 338 calc path gates
  on `safe?`.
- **B3**: `tenant_key.ex:44-73` regex-on-`inspect`; Ash Filter Inspect renders
  `#Ash.Filter<…>` (no `value:` substring) → function always returns `nil`.
- **B4**: Producer (`inbound.ex:153-161`) emits string-outer/atom-inner shape;
  consumer clauses (72-80) match neither. Clause 3 (`external?: true`) has no
  producer.
- **B5**: `validate_aggregate_overrides.ex:30` validates
  `local_evaluation_overrides` against aggregate names; `data_layer.ex:149`
  docs say "Calculation names"; `value_merge.ex:57` consumes as
  `calculation.name not in overrides`.
- **B6**: `flush.ex:233-234` compares `Snapshot.dump == entry.payload` with no
  `json_scalar`; lines 215-216 apply `json_scalar` for the field-level compare.
- **B7**: `api.ex:603-621` `ensure_resolvable_head` returns `:ok` for `:synced`;
  call sites at 111/131/191/238.
- **H1**: `data_layer.ex:320` takes only `tenant`; line 335 `request(cfg, :run,
  body)` with no headers; `remote_calculation.ex:74` memo key excludes
  actor/headers.
- **H2**: `data_layer.ex:198` `def upsert(_, _, _keys)`; lines 244-247 build
  filter from PK; lines 230-239 `put_write_action` rebuilds from PK attributes.
- **H3**: `api.ex:480` hard `{:ok, local_rows} =` match; `api.ex:387` raises on
  error; no `repo.transaction` wrapping the dirty-check + refresh.
- **H4**: `write.ex:52-98` `drain_chain_inline` reads-and-pushes with no lock.
- **H5**: `api.ex:565` `tenant_filter(query, nil) -> is_nil(tenant)`;
  `api.ex:437` `refresh(resource, :all)` with no tenant; `write.ex:273`
  stringifies tenant.
- **M1**: `write_dispatch.ex:58` passes `{:upsert_skipped, …}` as `{:ok,
  skipped}`; line 82 `TenantKey.changeset(resource, changeset, record)` with
  record=skipped-tuple → `Map.get` on tuple → `BadMapError`.
- **M2**: `tenant_key.ex:25` `metadata_tenant(record)` returns raw
  `record.__metadata__.tenant`; `proven_coverage.ex:198-200` calls
  `TenantKey.record` for changeset-less notifications.
- **M3**: `ash_multi_datalayer.ex:61` `forget_probe(resource, %resource{}
  = record)` returns record verbatim; PK-map clause (63-80) builds NotLoaded
  probe.
- **M4**: `api.ex:160-186` `discard_local` lacks `ensure_resolvable_head`;
  `drop_chain/1` at 530-537 re-reads `record_chain`; line 169 `backfill_opts(host)`
  omits entry.tenant.
- **M7**: `decoder.ex:61-77` calc/aggregate `place/4` clauses `Map.put` raw
  values; `cast_calculation/3` wired only to `{:remote_calc_meta, _}` (line 53).
- **M8**: `notifier.ex:67` `tenant = notification.changeset &&
  notification.changeset.to_tenant` → nil for changeset-less.
- **M9**: `discard/1` create-branch (137-140) and `drop_chain/1` (530-537) not
  in `transaction!`; `destroy_captured_chain` (271-292) IS in `transaction!`.
- **M10**: `api.ex:397` `{:ok, refresh(host_resource, :all, tenant)}` wraps
  `{:error, _}` in `{:ok, …}`.
- **M11**: `decoder.ex:26-32` has only `%{"results" => …}` and `is_list`
  clauses (no nil clause); `protocol.ex:62-63` collapses both
  `%{"success"=>true, "data"=>nil}` and `%{"success"=>true}` to `{:ok, nil}`.
- **P1**: `proven_coverage.ex:629` is the sole call site of
  `ensure_source_aggregates_resolved!`; unguarded paths at 226-227 (kill
  switch), 229-230 (single-layer), 262-271 (non-mergeable), 664+ (cold miss).
- **P3**: `proven_coverage.ex:471` `sort_references_uncomputable_calc?` matches
  only `%Query{sort: sort}` — ignores `distinct`/`distinct_sort`.
- **P4**: `invalidation.ex:89-91` `on_write` scans only
  `Coverage.entries(resource, tenant)`; comment at 72-73 defers cross-partition
  sweep.
- **L1**: `proven_coverage.ex:410` and `:598` both do
  `[pk] = Ash.Resource.Info.primary_key(resource)`.
- **L8**: `server.ex:349-411` dispatch + `fetch!/3` at 434-436 pass
  `subject_opts(opts)` (actor/tenant/context) but no `authorize?: true`.
- **L11**: Five normalizer sites verified: `write_dispatch.ex:162`,
  `write.ex:208`, `write.ex:314`, `backfill.ex:103-108`, `backfill.ex:125-126`.
- **L12 fixed-in-tree items**: item 3 (`capability.ex:38,56` handle
  `simple_expression`), item 4 (`supervisor.ex:62,68` filter
  `multi_datalayer?`), item 5 (`flush.ex:199-203` returns `{:conflict, nil}`),
  item 8 (`enqueue.ex:31` includes `write_ref`; `write.ex:217` generates it).
- **L13**: `router.ex:64-68` serves `/manifest.json` with no auth;
  `socket.ex:89-90` `id/1` returns nil; `connection.ex:29,170` consistent
  (item 4 fixed in tree).
- **Index #22 verifier**: `validate_layers.ex:146-157`
  `proven_coverage_authority_order/1` exists and checks
  `List.last(read_order) == hd(write_order)`.
