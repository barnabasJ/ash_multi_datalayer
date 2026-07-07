# Loop 2, Pane 6 — Fresh source-verified review of `docs/tasks/20260707-second-review-fixes/`

Reviewer performed a fresh, independent review of all 50 files in the task
tracker (`00-index.md` + every task file + `deferred-follow-ups.md`).
Every load-bearing defect claim and every file:line reference was verified
against the actual current source in `ash_multi_datalayer` (MDL) and
`/home/joba/sandbox/ash_remote` (ash_remote). ~85 source file:line refs
spot-checked across ~30 source files.

**Overall**: the tracker is in excellent shape. All blocker/high/medium/low
defect claims spot-verified as REAL in source (B1–B7, H1–H5, M1–M11, P1–P6,
L1–L13, PRE/A0/R0/FINAL). All ten loop-1 pane-5/pane-6 findings have been
properly incorporated into the task files (verified each correction against
source). The Cat A/B fixed-in-tree assertions all check out against the
uncommitted working tree (18 modified + 2 untracked MDL files; 16 modified
ash_remote files). Cross-task consistency, the B3-lead tenant unit, the
M3/L4 repro-20 split, and the PRE→retained-regression sequencing are all
internally consistent.

Findings below are the two actionable items found — neither rises above LOW.

---

## LOW

### L1 — B7 discard repro passes on unfixed code for `:create` entries

**File**: `b7-resolution-verb-synced-guard.md` (Done when, repro bullet)

**Claim under review**: "discard/rebase fail unfixed by destroying/mutating
the synced entry (`api.ex:130-146` for non-create discard, create-discard
re-reads `record_chain`). Assert the per-verb effect, not just 'a target push
happened'"

**What the source shows**: The B7 defect is that `ensure_resolvable_head/1`
(`api.ex:603-621`) returns `:ok` for `:synced` entries, letting verbs proceed.
For `discard/1` (`api.ex:130-149`):

- **Non-create branch** (line 144): `Ash.destroy!(entry, action: :discard, …)`
  destroys the synced entry directly. This IS a failure — the synced entry is
  destroyed and `kick_next/1` advances the chain. ✓ fails on unfixed code.

- **Create branch** (lines 134-142): calls `record_chain(entry)` at line 135.
  `record_chain/1` (`api.ex:518-528`) filters `state != :synced` at line 525,
  so a synced entry is **excluded** from its own chain. `chain` is `[]` (if no
  other non-synced entries), `Enum.each([], …)` destroys nothing, and the
  function returns `{:ok, %{discarded: 0, dropped_chain: true}}` — already a
  no-op success (the desired fixed behavior). `kick_next/1` is not called.

**Conclusion**: The task says "each verb called with a stale handle to a
now-`:synced` entry is a no-op success" and that discard "fails unfixed by
destroying/mutating the synced entry." But create-discard of a synced entry
is **already** a no-op success on unfixed code — `record_chain` excludes the
synced entry, nothing is destroyed, nothing is mutated. An implementer
writing the discard repro with a `:create` entry would find it **passes** on
unfixed code, contradicting the "fails on unfixed code" framing and
potentially concluding the discard case is already fixed when it is not (the
non-create branch still destroys synced entries).

The task's parenthetical "(api.ex:130-146 for non-create discard,
create-discard re-reads record_chain)" does distinguish the two branches and
hints that the failure is in the non-create path. But the repro criterion
itself says "each verb" without specifying which `entry.op` to use for
discard. The task should explicitly require the discard repro to use a
non-`:create` (update/destroy) entry, or acknowledge that create-discard is
already a no-op success for synced entries and needs no fail-first repro.

**Note**: `rebase/2` (`api.ex:237-258`) is unaffected — it applies the
resolution changeset (a real mutation) even when `record_chain` returns `[]`,
so it does fail on unfixed code regardless of `entry.op`.

---

### L2 — P4 expects B3's canonical function to own multi-partition derivation that B3 doesn't define

**Files**: `p4-global-tenant-invalidation.md` (Depends-on + Fix);
`b3-tenant-from-filter-dead-code.md` (Canonical representation section)

**Claim under review**: P4 says:

- "Depends on: B3 — the 'which partitions does this write touch' answer
  belongs in B3's canonical tenant function; consume it, do not add a local
  normalization"
- "Fold into the canonical tenant-key work (the partition-derivation function
  should own the 'which partitions does this write touch' answer)."

B3 says: "ONE shared function maps every tenant representation to the
canonical **partition string**" — a 1:1 mapping (tenant representation →
single partition string).

**What the source shows**: P4's defect (`invalidation.ex:84-105`,
`on_write/4` at line 90 scans only `Coverage.entries(resource, tenant)`) is
that for `global? true` resources, a tenant-scoped write must invalidate BOTH
the tenant partition AND `:__global__` (a 1:many relationship). This is a
different concern from B3's single-tenant → partition-string derivation.

B3's task defines a function that maps one tenant representation to one
canonical partition string. P4 needs a function that answers "which
partitions does this write touch" — which for `global?` resources returns
multiple partitions. B3's task does not mention `global?`, multi-partition
derivation, or extending the canonical function to return partition lists.

**Conclusion**: P4 says the multi-partition answer "belongs in B3's canonical
tenant function" and instructs the implementer to "consume it, do not add a
local normalization." But B3's function (as scoped in B3's task) only
handles 1:1 tenant → partition derivation. An implementer working P4 after B3
closes would find B3's function doesn't provide the multi-partition answer
P4 needs, and P4's "do not add a local normalization" instruction could be
read as prohibiting the multi-partition sweep logic.

The implementer can likely resolve this by using B3's function to derive
each individual partition (tenant partition + `:__global__` separately) and
adding the sweep-orchestration logic in P4 — the "do not add a local
normalization" instruction is about not re-deriving the canonical key, not
about the sweep logic. But the current task text creates a gap between P4's
expectation and B3's scope. Either B3's task should be extended to define
the multi-partition interface, or P4 should clarify that the
"which partitions" sweep logic lives in P4 (using B3's function per
partition), not in B3's canonical function itself.

---

## Loop-1 findings — all addressed

All ten findings from `loop-1-pane5.md` and `loop-1-pane6.md` have been
incorporated into the task files and verified against source:

- **H1 memo (pane-5 #1)**: H1 Done-when now has the "same-actor /
  different-headers memo repro" bullet. ✓
- **L8 `/rpc/validate` (pane-5 #2)**: L8 Done-when now has the
  "`/rpc/validate` covered" bullet citing `server.ex:309-330` / `router.ex:53`.
  ✓ (verified: `validate_action/3` at `server.ex:309-330` builds subjects via
  `subject_opts` with no `authorize?: true`; route at `router.ex:53`.)
- **B7 contract + discard repro (pane-5 #3)**: B7 now says "Pick ONE contract"
  and has per-verb failure-mode descriptions. ✓ (residual issue: L1 above.)
- **B4 Files range (pane-5 #4 / pane-6 L1)**: B4 header now says
  `external_change.ex:72-80`. ✓ (verified: three clauses at 72-74, 76-78, 80.)
- **L12 item 6 refs (pane-5 #5)**: L12 item 6 now cites `flush.ex:188-193`
  and `write.ex:305-308`. ✓ (verified: stale-check guard at 188-193 skips
  non-update/destroy; upsert before-image at `write.ex:305-308` returns nil.)
- **P6/H5 dependency (pane-6 M1)**: P6 now has the "Correction (loop-1
  review)" paragraph. ✓ (verified: sweeper at `sweeper.ex:42-46` reads
  unscoped with no `tenant_filter`; outbox `tenant` is a regular attribute.)
- **H2 "public" → all attributes (pane-6 L2)**: H2 scope note now says
  "all attributes (`Ash.Resource.Info.attributes/1` at `:370` — including
  `public? false` ones, NOT just public)." ✓ (verified at
  `data_layer.ex:369-370`.)
- **H3 helpers raise (pane-6 L3)**: H3 Done-when now has the loop-1
  correction parenthetical. ✓ (verified: `delete_local_pk/3` at
  `api.ex:387` raises; `reconcile_deletes` at `:480` hard-matches.)
- **L12 items 1-2 lines (pane-6 L4-L5)**: L12 now says `insert/3` at `:55`/
  `:57` and `phash2` at `:582`. ✓ (verified: `def insert/3` at `coverage.ex:55`,
  `:ets.insert` at `:57`; `:erlang.phash2()` at `:582`.)
- **B6 range (pane-6 L6)**: B6 header now says `flush.ex:231-235`. ✓
  (verified: `remote_matches_payload?/3` at 231-235.)
- **M6 both error classes (pane-6 L7)**: M6 Done-when now says "Cover BOTH
  error classes." ✓
- **M9 transaction! already correct (pane-6 I1)**: M9 now has the "Loop-1
  review (verified)" paragraph. ✓ (verified: `transaction!/2` at
  `api.ex:623-627` uses real Ecto `repo.transaction`; `destroy_captured_chain`
  at `:275` already runs inside it.)

---

## What was verified and found CORRECT (no action needed)

Spot-verified as accurate against source (non-exhaustive):

- **B1**: `fields.ex:133-134` use `Info.aggregate`/`Info.calculation`
  (non-public); `fields.ex:97-102` map `ForbiddenField`/`NotLoaded` to nil
  (#27 fix in-tree); `%Ash.NotSelected{}` does not exist in `deps/ash/lib/`.
- **B2**: `generator.ex:374-375` splice raw `aggregate_filter`; line 361
  `reproducible_aggregate?/1` checks only relationship; line 338 calc path
  gates on `safe?`.
- **B3**: `tenant_key.ex:44-73` regex-on-`inspect` (line 59); function always
  returns nil for Ash Filter inspect shape.
- **B4**: Producer (`inbound.ex:153-161`) emits string-outer/atom-inner
  shape; consumer clauses (72-80) match neither; clause 3 (`external?: true`
  at line 80) has no producer (grep confirmed — only the consumer matches).
- **B5**: `validate_aggregate_overrides.ex:30` validates
  `local_evaluation_overrides` against aggregate names; `data_layer.ex:149`
  doc says "Calculation names"; `value_merge.ex:57` consumes as
  `calculation.name not in overrides`.
- **B6**: `flush.ex:234` compares `Snapshot.dump == entry.payload` with no
  `json_scalar`; lines 215-216 apply `json_scalar` for the field-level compare.
- **B7**: `api.ex:603-621` `ensure_resolvable_head` returns `:ok` for
  `:synced`; call sites at 111/131/191/238.
- **H1**: `data_layer.ex:320` takes only `tenant`; line 335 `request(cfg, :run,
  body)` with no headers; `remote_calculation.ex:74` memo key excludes
  actor/headers.
- **H2**: `data_layer.ex:198` `def upsert(_, _, _keys)`; lines 244-247 build
  filter from PK; lines 230-239 `put_write_action` rebuilds from PK attributes;
  `accepted_keys/1` at `:369-370` uses `Ash.Resource.Info.attributes()`.
- **H3**: `api.ex:480` hard `{:ok, local_rows} =` match; `api.ex:387` raises;
  no `repo.transaction` wrapping the dirty-check + refresh.
- **H4**: `write.ex:52-98` `drain_chain_inline` reads-and-pushes with no lock;
  `push_all_targets` at 187-201 succeeds before `local_write` at 62.
- **H5**: `api.ex:565` `tenant_filter(query, nil) -> is_nil(tenant)`;
  `api.ex:437` `refresh(resource, :all)` with no tenant; `write.ex:273`
  stringifies tenant.
- **M1**: `write_dispatch.ex:82` passes `{:upsert_skipped, …}` to
  `TenantKey.changeset` → `Map.get` on tuple → `BadMapError`; `write.ex:222-223`
  passes it to `Snapshot.record_pk`.
- **M2**: `tenant_key.ex:25` `metadata_tenant(record)` returns raw
  `record.__metadata__.tenant`; `proven_coverage.ex:198-200` calls
  `TenantKey.record` for changeset-less notifications.
- **M3**: `ash_multi_datalayer.ex:61` `forget_probe(resource, %resource{} =
  record)` returns record verbatim; PK-map clause (63-80) builds NotLoaded
  probe; `proven_coverage.ex:172-183` routes to `forget!`.
- **M4**: `api.ex:160-186` `discard_local` lacks `ensure_resolvable_head`;
  `drop_chain/1` at 530-537 re-reads `record_chain`; line 169 `backfill_opts(host)`
  omits entry.tenant.
- **M6**: `backfill.ex:88-109` `destroy_record` returns `{:error, reason}` for
  any error — no "absent → :ok" mapping.
- **M7**: `decoder.ex:61-77` calc/aggregate `place/4` clauses `Map.put` raw
  values; `cast_calculation/3` wired only to `{:remote_calc_meta, _}` (line 53).
- **M8**: `notifier.ex:67` `tenant = notification.changeset &&
  notification.changeset.to_tenant` → nil for changeset-less.
- **M9**: `discard/1` create-branch (134-142) and `drop_chain/1` (530-537) not
  in `transaction!`; `destroy_captured_chain` (271-292) IS in `transaction!`.
- **M10**: `api.ex:397` `{:ok, refresh(host_resource, :all, tenant)}` wraps
  `{:error, _}` in `{:ok, …}`.
- **M11**: `decoder.ex:26-32` has only `%{"results" => …}` and `is_list`
  clauses (no nil clause); `protocol.ex:62-63` collapses both
  `%{"success"=>true, "data"=>nil}` and `%{"success"=>true}` to `{:ok, nil}`.
- **P1**: `proven_coverage.ex:629` is the sole call site of
  `ensure_source_aggregates_resolved!`; unguarded paths at 226-227 (kill
  switch), 229-230 (single-layer), 262-271 (non-mergeable), 517 (cold miss).
- **P3**: `proven_coverage.ex:471` `sort_references_uncomputable_calc?` matches
  only `%Query{sort: sort}` — ignores `distinct`/`distinct_sort`.
- **P4**: `invalidation.ex:90` scans only `Coverage.entries(resource, tenant)`;
  comment at 72-73 defers cross-partition sweep.
- **L1**: `proven_coverage.ex:410` and `:598` both do
  `[pk] = Ash.Resource.Info.primary_key(resource)`.
- **L2**: `example/todo_client/test/todo_client/live_test.exs:92` asserts
  `todo_count == 2`; `proven_coverage.ex:422` `copy_aggregate_values(row, nil,
  _aggs) -> row` leaves NotLoaded.
- **L11**: Five normalizer sites verified: `write_dispatch.ex:162`,
  `write.ex:208`, `write.ex:314`, `backfill.ex:106`, `backfill.ex:125`.
- **L12 fixed-in-tree items**: item 3 (`capability.ex:38,56` handle
  `simple_expression`), item 4 (`supervisor.ex:62,68` filter
  `multi_datalayer?`), item 5 (`flush.ex:199-203` returns `{:conflict, nil}`),
  item 8 (`enqueue.ex:31` includes `write_ref`; `write.ex:217` generates it).
- **L13**: `router.ex:64-68` serves `/manifest.json` with no auth;
  `socket.ex:90` `id/1` returns nil; `connection.ex:29,170` consistent.
- **Index #22 verifier**: `validate_layers.ex:146-157`
  `proven_coverage_authority_order/1` checks
  `List.last(read_order) != hd(write_order)`.
- **P5**: `mix.exs:54` has `{:crux, "0.1.3", override: true}`; no
  `package`/`description` config.
- **PRE**: Git status confirms 18 modified + 2 untracked MDL files; 16
  modified ash_remote files — all uncommitted.
- **L10**: `write.ex:233` comment says "there is no background sweeper" while
  `local_outbox.ex:226` starts `Sweeper` child spec; `backfill.ex:8-9` moduledoc
  says "ALL resource attributes" while `default_fields/2` at `:128-133` filters
  NotLoaded.
