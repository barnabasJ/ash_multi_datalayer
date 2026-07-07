# Loop 3, Pane 6 — Fresh source-verified review of `docs/tasks/20260707-second-review-fixes/`

Reviewer performed a fresh, independent review of all 50 files in the task
tracker (`00-index.md` + 46 task files + `deferred-follow-ups.md` + the
`pre-checkpoint-commit.md`/`final-gates.md` cross-cutting files). Every
load-bearing defect claim and every file:line reference was verified against the
actual current source in `ash_multi_datalayer` (MDL) and
`/home/joba/sandbox/ash_remote` (ash_remote). ~85 source file:line refs
spot-checked across ~30 source files, via two parallel verification passes plus
direct re-verification of every candidate discrepancy against the live source.

**Overall**: the tracker remains in strong shape. Every DEFECT claim (the actual
code behavior) is CONFIRMED REAL in source — B1–B7, H1–H5, M1–M11, P1–P6,
L1–L13, PRE/A0/R0/FINAL. No false claims about current code behavior were found.
The Cat A/B fixed-in-tree assertions all check out against the uncommitted
working tree (18 modified + 2 untracked MDL files; 16 modified ash_remote files
— all confirmed via `git status`). Both loop-2 findings (B7 create-discard repro
semantics; P4/B3 multi-partition scope split) are fully incorporated and
verified.

Two actionable findings below — one MEDIUM (a self-contradiction on a binding
design decision), one LOW (a stale line ref that both prior loops verified
incorrectly). Plus a short list of non-actionable minor notes.

---

## MEDIUM

### M1 — Unscoped-sentinel ownership is self-contradictory (H5 Fix vs H5 Done-when; index vs B3)

**Files**: `h5-localoutbox-nil-tenant-model.md` (Fix lines 42-48 vs Done-when
lines 61-64); `00-index.md` (lines 140-143, 154);
`b3-tenant-from-filter-dead-code.md` (Fix lines 76-83, Done-when lines 90-93)

The index's "Canonical tenant decision" (declared **binding** for
B3/H5/M2/L3/P4) separates three concepts: (1) canonical partition key [B3],
(2) unscoped sentinel [H5], (3) target-call tenant value [H5]. But the task
files contradict each other — and **H5 contradicts itself** — on who PICKS the
sentinel value.

**"B3 picks the sentinel" — 3 citations:**
- B3 Fix (`b3-tenant-from-filter-dead-code.md:76-83`): lists the unscoped
  sentinel as one of "Two normalization points that MUST be pinned in the
  function" — "unscoped sentinel: reconcile the read-side `:__global__` and
  H5's proposed `:all` into ONE value used everywhere … **Pick one** and make
  every path use it."
- B3 Done-when (`b3-…:90-93`): "The canonical function … lands first … with a
  pinned signature + normalization rules (integer/atom via `to_string`,
  **single unscoped sentinel**)."
- H5 Fix (`h5-localoutbox-nil-tenant-model.md:42-48`): "using **the unscoped
  sentinel chosen by B3** (the binding decision reconciles read-side
  `:__global__` with `:all` … **B3 picks it, H5 consumes it**)."

**"H5 owns/reconciles the sentinel" — 3 citations:**
- Index (`00-index.md:140-143`): "Unscoped scope sentinel — … **(H5)**.
  **Reconcile** coverage's `:__global__` with H5's proposed `:all` into ONE
  sentinel."
- Index (`00-index.md:154`): "**H5 additionally owns the unscoped sentinel**
  (concept 2)."
- H5 Done-when (`h5-…:61-64`): "H5 **owns the single unscoped sentinel**
  (**reconciling** `:__global__`/`:all`)."

**The contradiction.** H5's own Fix (line 43-45) says "B3 picks it, H5 consumes
it," while H5's own Done-when (line 62-63) says "H5 owns the single unscoped
sentinel (reconciling `:__global__`/`:all`)." "Reconciling" is the act of
deciding/picking the value — so H5 both merely consumes B3's choice AND
independently reconciles/picks it. The index compounds the split by assigning
concept 2 (sentinel) to H5, while B3's task folds the sentinel into B3's own
"normalization rules" pinned in B3's function.

**Impact.** B3 is the lead and lands first. An implementer working B3 reads
"pin the sentinel, pick one" and selects a value. An implementer working H5
after B3 closes reads H5's Done-when ("H5 owns the sentinel, reconciling
`:__global__`/`:all`") and may re-reconcile / re-pick a value B3 already pinned
— diverging from B3's choice on exactly the "one shared value used everywhere"
property the binding decision exists to protect. The checklist (Done-when) is
typically read as the closure gate, so the "H5 owns" wording there is the more
dangerous of the two.

**Practical mitigation.** The weight of evidence (B3 Fix + B3 Done-when + H5
Fix) says B3 picks, and H5's Fix is explicit ("B3 picks it, H5 consumes it").
So the likely outcome is B3 picks and H5 consumes — but the Done-when / index
"H5 owns / reconciles" wording is a real trap for an H5 implementer who reads
the checklist without cross-referencing the Fix.

**Recommendation.** Pick ONE owner of the sentinel VALUE and make all four
citation sites agree. Given B3 lands first and three of four citations already
say B3 picks, the cleanest fix is: B3 owns the value; correct the index
(lines 140-143, 154) and H5's Done-when (lines 61-64) to "H5 **consumes** B3's
sentinel and applies it to the unscoped scan paths" — not "H5 owns / reconciles
the sentinel." (Alternatively, if the index's intent — sentinel = H5's concept 2
— is to stand, then B3's task lines 76-83 / 90-93 and H5's Fix lines 43-45 must
stop claiming B3 picks it.) Either way, the four citations must not continue to
split the ownership.

---

## LOW

### L1 — L12 item 1 `coverage.ex` line refs off by one (both prior loops verified the wrong lines)

**File**: `l12-mdl-misc-lows.md` (item 1, line 16)

The task says: "the `:ets.insert` call at `coverage.ex:57`; `def insert(resource, tenant, entry)` at `:55`." The actual current source
(`lib/ash_multi_datalayer/coverage.ex`):

```
54:   @doc "Inserts a ledger entry (keyed by `entry.id`) for a resource+tenant."
55:   @spec insert(module(), term(), %{:id => term(), optional(any()) => any()}) :: :ok
56:   def insert(resource, tenant, entry) do
57:     table = TableOwner.table_name(resource)
58:     true = :ets.insert(table, {{tenant_key(tenant), entry.id}, entry})
```

- `def insert` is at **line 56**, not 55 (line 55 is the `@spec`).
- `:ets.insert` — the call lacking the `ArgumentError` rescue — is at **line
  58**, not 57 (line 57 is `table = TableOwner.table_name(resource)`).

Both cited lines land one line ABOVE the relevant code. The DEFECT itself (no
`ArgumentError` rescue, unlike `drop/3` at 64-69 and `entries/2` at 49-52 which
both rescue) is REAL and verified — only the line numbers are stale.

**Why this is a fresh catch.** Loop-1 "corrected" the `:ets.insert` line from
`:56` to `:57`, and the task now carries that correction; loop-2 then verified
`:55` / `:57` as exact. But `git blame` shows the `@spec` line (55) was added in
commit `961148cf` (2026-07-03 19:45:54) — **before** either loop ran
(2026-07-07). So `def insert` has been at line 56 and `:ets.insert` at line 58
for both prior loops; both missed it. The task's own parenthetical ("Loop-1
review: it's `insert/3` and line 57, not `insert/2`/`:56`") is itself now wrong
on the line number.

---

## Minor non-actionable notes (recorded so the next loop doesn't re-derive)

These are range-END truncations or prose arities where the START /
load-bearing line is correct, so an implementer is not misled. Not elevated to
findings:

- `00-index.md:304` and `a0-mdl-repro-harness.md:54` cite the #22
  authority-order verifier as `validate_layers.ex:146-152`; actual is
  **146-157** (line 152 is mid-message-string). Start (146) is correct. Loop-2's
  own "verified correct" section used 146-157 but did not reconcile the two task
  files.
- `m11-decoder-crashes-nil-single-object.md` Files header says
  `decoder.ex:26-31`; actual is **26-32** (misses the final `end`). The body and
  loop-2 used 26-32.
- `h1-remote-calc-fetch-unauthenticated.md` Files header says
  `remote_calculation.ex:68-84`; actual `fetched_values/4` spans **68-92**. The
  load-bearing memo-key line (74) is exact.
- `h2-non-pk-upsert-identity-accept-truncation.md` Files header says
  `:369-370`; the fallback clause is **369-371**. The body (lines 27-28) and
  Fix (line 45) cite 369-371 / 367 correctly — the header is the only stale
  one.
- `h3-refresh-toctou.md` (line 49) says `delete_local_pk/3`; actual arity is
  **/5** (`api.ex:377`). The cited line range (386-388, the raise clause) is
  correct.
- `h4-write-through-drain-race-divergence.md` Files header says
  `write.ex:52-98`; `drain_chain_inline` proper starts at **67** (52 is the
  parent `write_through`). The range covers both; loop-2 signed off.

---

## Loop-1 / loop-2 findings — all addressed

Both prior loops' findings are incorporated and re-verified against source:

- **loop-2 L1** (B7 create-discard repro): B7 Done-when now explicitly requires
  a non-`:create` entry for the discard repro and notes create-discard is
  already a no-op (`record_chain` at `api.ex:518-528` filters `state != :synced`
  at `:525`). ✓
- **loop-2 L2** (P4/B3 multi-partition): P4 now has the "Scope split vs B3
  (loop-2 review)" paragraph — B3's function is 1:1, P4's 1:many
  sweep-orchestration lives in P4. ✓ (verified: B3's task scopes its function
  to 1:1 tenant→partition; P4 owns the multi-partition sweep.)
- All ten loop-1 findings remain incorporated (B4 range, H2 "all attributes",
  H3 helper-raise correction, L12 item 1/2 lines, B6 range, M6 both error
  classes, P6/H5 dependency, M9 transaction, B7 contract) — re-confirmed present
  in the task files.

---

## What was verified and found CORRECT (no action needed)

Spot-verified as accurate against current source (non-exhaustive; ~85 refs
checked across both repos):

- **B1**: `fields.ex:132-135` (public attr/rel vs non-public agg/calc);
  `:97-102` map `ForbiddenField`/`NotLoaded`→nil (#27 in-tree); `NotSelected`
  absent from `deps/ash/lib/` (grep empty).
- **B2**: `generator.ex:374-375` raw `aggregate_filter` splice; `:361`
  `reproducible_aggregate?` relationship-only; `:338` calc `safe?` gate.
- **B3**: `tenant_key.ex:49` `inspect(limit: :infinity)`, `:59` regex; always-nil
  for an `%Ash.Filter{}` (operator-syntax inner rendering — `value:` substring
  never appears).
- **B4**: `external_change.ex:72-74 / 76-78 / 80` three clauses; producer
  `inbound.ex:153-161` emits string-outer / atom-inner — matches neither clause
  1 (string inner) nor clause 2 (atom outer); clause 3 has no producer.
- **B5**: `validate_aggregate_overrides.ex:30` validates
  `local_evaluation_overrides` against `aggregates/1`; `data_layer.ex:149` doc
  "Calculation names"; `value_merge.ex:57` consumes as `calculation.name`.
- **B6**: `flush.ex:234` `Snapshot.dump == entry.payload` no `json_scalar`;
  `:215-216` field-level compare normalizes.
- **B7**: `api.ex:603-621` `:synced -> :ok`; call sites 111/131/191/238;
  `:144` destroy, `:135` `record_chain`, `record_chain/1` `:518-528` (`:525`
  filter), `rebase/2` `:237-258` applies changeset on empty chain.
- **H1**: `data_layer.ex:320` tenant-only; `:335` `request(cfg, :run, body)` no
  headers; `remote_calculation.ex:74` memo key `{__MODULE__, resource,
  phash2({pk_values, specs, context.tenant})}` excludes actor/headers.
- **H2**: `data_layer.ex:198` `_keys`; `:244-247` PK filter; `:230-239`
  `put_write_action` rebuilds from PK; `:211-214` retry PK; `accepted_keys`
  `:367` / `:369-371` uses `Ash.Resource.Info.attributes()` (all attrs).
- **H3**: `api.ex:480` hard `{:ok, local_rows} =`; `:387` raise; no
  `repo.transaction` wraps the dirty-check + refresh.
- **H4**: push (`write.ex:61`) before `local_write` (`:62`); no lock in
  `drain_chain_inline`.
- **H5**: `api.ex:565` `nil → is_nil(tenant)`; `:435-441` / `:308` /
  `:496-514`; `write.ex:273` stringify.
- **M1**: `write.ex:213-240` + `write_dispatch.ex:82` + `tenant_key.ex:16,33-39`
  — `{:upsert_skipped, …}` as record → `Map.get` on tuple → `BadMapError`.
- **M2**: `tenant_key.ex:25 / :41` raw `metadata[:tenant]`;
  `proven_coverage.ex:198-200` `TenantKey.record` for changeset-less.
- **M3**: `ash_multi_datalayer.ex:61` `%resource{}` clause returns verbatim;
  `:63-80` PK-map clause builds `%Ash.NotLoaded{}` probe.
- **M4**: `api.ex:160-186` no `ensure_resolvable_head`; `:534` re-reads
  `record_chain`; `:169` `backfill_opts(host)` omits `entry.tenant`.
- **M6**: `backfill.ex:88-109` no absent→`:ok` mapping.
- **M7**: `decoder.ex:61-77` four `place/4` clauses `Map.put` raw values;
  `cast_calculation/3` only at `:53` (`{:remote_calc_meta, _}`).
- **M8**: `notifier.ex:67` `changeset && changeset.to_tenant` → nil for
  changeset-less.
- **M9**: `api.ex:137-140` & `:530-537` not in `transaction!`; `:271-292` IS;
  `transaction!/2` `:623-627` real Ecto `repo.transaction`.
- **M10**: `api.ex:397` `{:ok, refresh(host_resource, :all, tenant)}` wraps
  `{:error, _}`.
- **M11**: `decoder.ex:26-32` two clauses, no nil; `protocol.ex:62-63` both
  `%{"success"=>true, "data"=>nil}` and `%{"success"=>true}` → `{:ok, nil}`.
- **P1**: `proven_coverage.ex:629` sole call site of
  `ensure_source_aggregates_resolved!`; unguarded paths at 226-227 / 229-230 /
  262-271 / 517.
- **P3**: `proven_coverage.ex:471` `sort_references_uncomputable_calc?` matches
  only `%Query{sort: sort}`.
- **P4**: `invalidation.ex:90` scans only `Coverage.entries(resource, tenant)`;
  comment `:72-74` defers cross-partition sweep and names it "M6".
- **L1**: `proven_coverage.ex:410` and `:598` both `[pk] = … primary_key`.
- **L2**: `proven_coverage.ex:422` `copy_aggregate_values(row, nil, _aggs) -> row`.
- **L3**: `write.ex:55` keys drain on `changeset.data` PK (nil for creates);
  `tenant_key.ex:37` `Map.get` on changeset (not `.attributes`).
- **L5**: `sweeper.ex:60-62` `{:global, {__MODULE__, sorted}}`; `:42-49` unscoped
  read (no tenant filter).
- **L10**: `write.ex:233` "there is no background sweeper" comment;
  `local_outbox.ex:226` starts a `Sweeper` child; `backfill.ex:8-9` moduledoc
  "ALL resource attributes" vs `:128-133` `default_fields` filters NotLoaded.
- **L11**: five `{:error, :no_rollback, reason}` → `{:error, reason}` normalizer
  sites at `write_dispatch.ex:162`, `write.ex:208` & `:314`,
  `backfill.ex:103-108` & `:125-126` — all confirmed.
- **L12**: item 2 `coverage.ex:582` `phash2` / `:371` fingerprint match
  (CONFIRMED); items 3/4/5/8 fixed-in-tree (`capability.ex:38,56`;
  `supervisor.ex:62,68`; `flush.ex:199-203`; `enqueue.ex:31` + `write.ex:217`).
- **L13**: `router.ex:64-68` no-auth `/manifest.json`; `socket.ex:89-90` `id→nil`;
  `connection.ex:29,170` consistent; `channel.ex:49 / 87 / 143`.
- **#22 verifier**: `validate_layers.ex:146-157`
  `proven_coverage_authority_order/1`, operator `!=` (errors when last-read ≠
  hd-write).
- **P5**: `mix.exs:54` `{:crux, "0.1.3", override: true}`; no `package` /
  `description`.
- **PRE**: `git status` confirms 18 modified + 2 untracked MDL `lib/` files
  (`tenant_key.ex`, `sweeper.ex`); 16 modified ash_remote `lib/` files — all
  uncommitted.
