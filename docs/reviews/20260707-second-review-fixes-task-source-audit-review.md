# Independent source-audit review: `20260707-second-review-fixes/` task files

**Date**: 2026-07-07
**Reviewer**: independent pass — every blocker/high/medium defect claim and every
"fixed-in-tree" assertion hand-verified against current `lib/` in both repos,
plus the cross-task dependency graph and the deferred/final-gate closure logic.
**Subject**: all 45 task files + index in
[`docs/tasks/20260707-second-review-fixes/`](../tasks/20260707-second-review-fixes/).
**Method**: read all 47 files in the directory, the source implementation review
([`…fix-plan-implementation-review.md`](20260707-second-review-fix-plan-implementation-review.md)),
the plan ([`…fix-plan.md`](../plans/20260706-second-review-findings-fix-plan.md)),
the two prior deep passes
([technical](20260707-second-review-fixes-task-technical-review.md) +
[spec](20260707-second-review-fixes-task-spec-review.md)), and verified each
load-bearing code claim by reading the cited file at the cited line.

This review is deliberately **non-overlapping** with the prior seven: it expands
the source-verification surface (§A) and looks for *new* issues the technical
and spec passes did not raise (§B). The technical review spot-verified 12 claims;
this one verifies ~35, including every "fixed-in-tree" item and the feasibility
of every proposed fix.

---

## Verdict — execution-ready; one spec clarification worth pre-fixing

The task set is technically accurate, internally consistent, and the proposed
fixes are all feasible against the current code. **No ship-blocking defect was
found in the task files themselves**, and the defect claims they describe were
verified end-to-end against source for every blocker, every high, most mediums,
and every "fixed-in-tree" assertion.

The findings below are **all Low severity** — one under-specified fix description
(M3), two minor doc/wording items (M3 again, index status workflow), and a
handful of "verified, no action" confirmations that strengthen confidence in the
prior reviews' sign-off. None blocks execution. They are worth ~10 minutes of
task-file edits to reduce fixer confusion, after which the tracker can be worked
straight through in the recommended order.

---

## §A — Source verification (all PASSED)

Each row: task claim → code reality at the cited location. The technical review
already verified B1–B7, H3, H5, M1, M2, M3, P1, P3, L1; this pass covers the
remainder plus the feasibility of every fix and every "fixed-in-tree" assertion.

### Blockers (all re-confirmed, fix feasibility verified)

| Task | Claim verified | Code at citation | Fix feasibility | Result |
| ---- | -------------- | ---------------- | --------------- | ------ |
| **B1** | `aggregate?`/`calculation?` use non-public `Info.aggregate`/`Info.calculation` | `fields.ex:133-134` — exactly as claimed | `Info.public_aggregate/2` (`info.ex:620`) and `Info.public_calculation/2` (`:557`) both exist in the pinned Ash — fix is a 2-line swap | ✅ |
| **B1 sub** | `value/1`+`loaded/1` handle NotLoaded+ForbiddenField but no `NotSelected`; `Ash.NotSelected` does not exist | `fields.ex:97-102`; `deps/ash/lib/ash/` has no `not_selected.ex`; `not_loaded.ex:6` moduledoc "haven't been loaded **or selected**"; `:type` field includes `:attribute` | sentinel correction in B1 task is accurate | ✅ |
| **B2** | `aggregate_block/2` splices `field.aggregate_filter` raw, no `safe?` gate | `generator.ex:374-375` | calc path at `:338` shows the gate to mirror | ✅ |
| **B3** | `tenant_from_filter/2` regexes `inspect(filter)` for `value: X` | `tenant_key.ex:44-63` — `inspect(limit: :infinity)` + `~r/…value: ([^,}\]]+)/` | structural walk or row extraction per task | ✅ |
| **B4** | `replayed_external?/1` 3 clauses; producer emits string-outer/atom-inner | `external_change.ex:72-80` (3 clauses incl. `external?: true`); `inbound.ex:156-160` (`Map.put(user_meta, "ash_remote", %{origin: :remote, …})`) | match real shape; `external?: true` clause also dead (no producer sets it — grep-confirmed) | ✅ |
| **B5** | verifier validates `local_evaluation_overrides` vs aggregate names | `validate_aggregate_overrides.ex:29-40` — all 3 options vs `aggregate_names`; consumer `value_merge.ex:54-57` compares `calculation.name not in overrides`; `data_layer.ex:148` doc "Calculation names…" | validate vs calc names for that one option | ✅ |
| **B6** | `remote_matches_payload?` skips `json_scalar` that lines 210-217 apply | `flush.ex:231-235` vs `:209-217` | apply same normalization (already a private helper at `:240`) | ✅ |
| **B7** | `ensure_resolvable_head` returns `:ok` for `:synced` | `api.ex:603-621` | invert the guard | ✅ |

### Highs (fix feasibility verified)

| Task | Claim verified | Code at citation | Fix feasibility | Result |
| ---- | -------------- | ---------------- | --------------- | ------ |
| **H1** | `fetch_remote_calculations` uses `request(cfg, :run, body)` with no headers | `data_layer.ex:335`; read path at `:130` uses `request_headers(query.context)` | thread `context` + `request_headers/1` (exists at `:414`) | ✅ |
| **H2** | `upsert/3` ignores `keys`; `input/1` truncates to `action.accept` | `data_layer.ex:198` (`_keys`); `:360-365` (`Map.take(accepted_keys(changeset))`) | build filter from `keys`; note `accepted_keys/1` falls back to all public attrs when no explicit `accept` (see §B-3) | ✅ |
| **H3** | `co_commit_repo/3` exists for the fix | `write.ex:351` (`def co_commit_repo/3`), used `:218` + `local_outbox.ex:200` | wrap refresh path in the same transaction | ✅ |
| **H4** | `drain_chain_inline` no per-PK lock; no entry re-check; no compensation | `write.ex:52-98` | per task | ✅ |
| **H5** | `tenant \\ nil` → `filter(is_nil(tenant))`; entries stringified at `write.ex:273` | `api.ex:559-566` (`tenant_filter`); `:435-441` (`boot_hydrate` calls with no tenant) | per task + B3 canonical function | ✅ |

### Mediums (fix feasibility verified)

| Task | Claim verified | Code at citation | Result |
| ---- | -------------- | ---------------- | ------ |
| **M1** | `async_run` passes `record` through to `Snapshot.record_pk`; if `local_write` returns `{:upsert_skipped, ...}`, `record` is the tuple | `write.ex:222-223` → `enqueue_entries(..., record, ...)`; `snapshot.ex:46` `record_pk` does `Map.get(record, pk)` | ✅ |
| **M3** | `forget_probe` `%resource{}` clause returns record verbatim; PK-map clause builds PK-only probe | `ash_multi_datalayer.ex:61` vs `:63-69` | ✅ (see §B-1 on the fix wording) |
| **M7** | `place/4` for `{:calculation,_}`/`{:aggregate,_}` `Map.put`s raw wire value; `cast_calculation/3` not wired to read plan | `decoder.ex:61-77` | ✅ |
| **M8** | `tenant = notification.changeset && notification.changeset.to_tenant` → nil for changeset-less | `notifier.ex:67` | ✅ |
| **M10** | `hydrate` wraps `refresh(...)` in `{:ok, ...}` unconditionally | `api.ex:392-399`; spec at `:392` says `{:ok, map} \| {:error, :outbox_not_empty}` | ✅ |
| **M11** | `decode_records/3` has only `%{"results" => _}` and `is_list` clauses | `decoder.ex:26-32` | ✅ |

### Lows + P-family (spot checks)

| Task | Claim verified | Code at citation | Result |
| ---- | -------------- | ---------------- | ------ |
| **L7** | header dedup: `request_headers/1` lowercases keys and dedupes via `Map.new` but with no defined precedence (last-wins from list order) | `data_layer.ex:414-418` | ✅ — current code dedupes but precedence is non-deterministic; task correctly asks for an explicit rule |
| **L9** | destroy notifications dropped when filter undecidable | `channel.ex:140-141` (`refetch_visible?` for destroy → `false`) | ✅ |
| **L10** | `write.ex:233` "there is no background sweeper" vs sweeper module exists | `write.ex:230-233` comment; `sweeper.ex` is an untracked live module | ✅ |
| **L11** | `{:error, :no_rollback, reason}` normalized to `{:error, reason}` | `write.ex:208` (`defp normalize({:error, :no_rollback, error}), do: {:error, error}`) | ✅ |
| **P4** | `invalidation.ex:73` comment "M6" = 20260704 review's M6 (global? cross-partition), not this tracker's M6 (destroy-flush-parks) | 20260704 review line 293: "M6. Multitenancy with `global? true`" | ✅ — P4's disambiguation is correct |
| **P6** | sweeper module exists (untracked) with zero tests; `Enum.each(&Enqueue.flush(...))` discards errors | `sweeper.ex:49` | ✅ |
| **L5** | sweeper `name: {:global, {__MODULE__, sorted}}` | `sweeper.ex:60-62` | ✅ |

### "Fixed-in-tree" assertions (all 5 verified present in current working tree)

These are the items the index says are already fixed in the uncommitted tree but
need retained regression tests. **All five confirmed present:**

| Item | Task claim | Verified at | Result |
| ---- | ---------- | ----------- | ------ |
| **B1 #27 half** | `value/1`/`loaded/1` map `%Ash.NotLoaded{}` + `%Ash.ForbiddenField{}` to nil | `fields.ex:97-102` | ✅ |
| **L12 item 3** | `Capability.collect` handles `simple_expression` | `capability.ex:38-39,55-57` | ✅ |
| **L12 item 4** | Supervisor filters by `multi_datalayer?/1` on both `resources:` and `otp_app:` paths | `supervisor.ex:62,68` | ✅ |
| **L12 item 5** | Stale-check returns `{:conflict, nil}` for missing-row update with base_image | `flush.ex:199-203` | ✅ |
| **L12 item 8** | `enqueue.ex:31` includes `"write_ref" => entry.write_ref` in Oban job args | `enqueue.ex:31`; generated at `write.ex:217` | ✅ |
| **L13 item 4** | `connection.ex:29` and `:170` doc comments now consistent | `connection.ex:29-36,170-172` | ✅ (docs-only — no repro required) |

### Structural confirmations

- **Plan A0 repro numbering is faithful**: every `plan A0 repro N` cited in a task
  matches the plan's numbered list at
  `plans/20260706-second-review-findings-fix-plan.md:72-121` (repros 3, 6, 7, 9,
  10, 11, 13, 15, 19, 20 all checked). A0 repro 20 bundles A2–A5 together in the
  plan; M3 and L4 both correctly cite it as "repro 20, A2/A3 part" — no collision.
- **Deferred RFC exists**: `deferred-follow-ups.md` references
  `docs/design/20260706-atomic-capability-delegation-rfc.md` — file is present.
- **Zero new test files (confirmed)**: `git status --short` in both repos shows
  only modifications to existing test files; no untracked `*_test.exs`. Matches
  the implementation review's "zero new test files" claim that motivates A0/R0.
- **Tenant unit is a true unit**: B3/H5/M2/L3/P4 all reference each other and
  the canonical-tenant decision; B3 is correctly designated the lead (it owns
  `tenant_key.ex`). No circular or missing dependency.

---

## §B — New findings (all Low)

### B-1 — M3's "one-line fix" description is two-partly misleading

**Task ref**: `m3-external-update-after-image-row-before.md:32-35`
**Code ref**: `ash_multi_datalayer.ex:53-69` (`forget!` + `forget_probe`)

M3's Fix section says:

> One line, per the review: `Map.take(record, primary_key)` (route full records
> through the same PK-only unknown-before path `forget_probe` already has for PK
> maps), and pass the record as the after-image where the invalidation math
> wants it.

Two issues:

1. **It is not one line.** The current first clause is
   `def forget_probe(resource, %resource{} = record), do: record`. The fix is to
   make this clause delegate to the PK-map clause, i.e.
   `def forget_probe(resource, %resource{} = record), do: forget_probe(resource, Map.take(record, Ash.Resource.Info.primary_key(resource)))`
   — a one-clause change but not a one-liner. A fixer reading "one line" may
   expect a single-line edit and be surprised by the need to reference
   `primary_key/1` and recurse.

2. **"pass the record as the after-image where the invalidation math wants it"
   contradicts the conservative posture.** `forget!/3` currently calls
   `Invalidation.on_write(resource, tenant, row_before, nil)` — the 4th argument
   (after-image) is deliberately `nil`. The `handle_external_change` comment at
   `proven_coverage.ex:168-170` explicitly says this is the "sound reaction under
   at-most-once notification delivery" (drop-then-refetch, not in-place refresh).
   Telling the fixer to "pass the record as the after-image" reads as a
   suggestion to change `nil` to the record, which would contradict that
   conservative posture. The actual defect (row_before should be PK-only) is
   fully fixed by part 1 alone; part 2 is either stale or describes future work
   that isn't this task's scope.

**Recommendation**: rewrite M3's Fix to "Make `forget_probe`'s `%resource{}`
clause delegate to its PK-map clause (build a PK-only probe), so `row_before`
passed to `on_write/4` is PK-only-unknown. The after-image (4th arg of
`on_write/4`) stays `nil` — the drop-then-refetch posture is unchanged." Drop
the "one-line" and "pass the record as the after-image" phrasing.

### B-2 — Index status workflow omits `DEFERRED`

**Task ref**: `00-index.md:42-43, 157-162`; `deferred-follow-ups.md:3-4`

The index defines the status workflow as:

> Statuses: `OPEN` → `IN PROGRESS` → `FIXED (unverified)` → `DONE` (repro test
> in suite + full suite green). Use `WONTFIX (reason)` only with a recorded
> decision.

But `deferred-follow-ups.md` uses `Status: DEFERRED`, and individual task files
(e.g. L9, L13 item 3) reference "moved to deferred-follow-ups.md" as a
completion path. `DEFERRED` is a load-bearing status that appears in the
tracker but isn't in the workflow enumeration. A reader scanning only the
workflow line could conclude that moving an item to deferred-follow-ups is not
a recognized closure.

**Recommendation**: add `DEFERRED` to the workflow line — e.g.
"…or `DEFERRED` (recorded in `deferred-follow-ups.md`)" — so the parked list's
status is canonically recognized.

### B-3 — H2 understates the `accepted_keys` fallback

**Task ref**: `h2-non-pk-upsert-identity-accept-truncation.md:21-23`
**Code ref**: `data_layer.ex:367-371`

H2's defect description says the update path's `input/1` does
`Map.take(attributes, accepted_keys)` where `accepted_keys = action.accept`.
That's accurate for the truncation case, but `accepted_keys/1` has a fallback at
lines 369-371: when the changeset's action has no explicit `accept`, it returns
**all public attribute names** — so no truncation occurs for actions without an
explicit accept list. A fixer implementing "bypass action `accept` truncation
for action-less backfill/replication update paths" should know the truncation
only bites when `action.accept` is set; the action-less path is already safe.

This isn't wrong (the defect is real for the explicit-accept case), just
under-specified — the fix scope is narrower than a naive read suggests.

**Recommendation**: add a one-line note to H2's defect or fix — "truncation
only occurs when the action has an explicit `accept` list; the action-less
fallback (`accepted_keys/1` at `data_layer.ex:369-371`) already returns all
public attributes."

### B-4 — Index "Recommended order" step 2 omits L3's non-tenant half

**Task ref**: `00-index.md:166-172`

Step 2 names "B3 + H5 + M2 + P4 (plus L3's tenant half)" as the tenant unit.
L3 has two distinct halves: (a) the tenant half (`attribute_value` should read
`changeset.attributes` for creates) and (b) the create-PK drain half
(`write_through`'s inline drain keys on `changeset.data`'s PK, nil for creates).
L3 itself correctly notes "Related task: H4 (same function)" for the drain half,
but the index's ordered list doesn't mention that L3's drain half should be
coordinated with H4 (step 5). A fixer working the tenant unit in step 2 could
land L3's tenant half and leave the drain half for H4, which is fine — but the
split isn't visible from the ordered list alone.

**Recommendation**: one-line index note beside step 2 — "L3 has a second
(non-tenant) half — the create-PK drain bug in `write_through` — that
coordinates with H4 in step 5, same function."

---

## §C — Verified non-issues (confirming prior sign-offs)

These came up during verification and are **not** findings — recorded here so
the next reviewer doesn't re-investigate:

- **B1 fix feasibility**: `Info.public_aggregate/2` and `Info.public_calculation/2`
  both exist in the pinned Ash (`deps/ash/lib/ash/resource/info.ex:557,620`). The
  fix is a 2-line swap with no version dependency.
- **B4 third clause**: grep across both repos + `example/` confirms **no producer
  sets `%{external?: true}`** — the clause is dead, exactly as the technical
  review's F1 and B4's task both state. The task correctly requires deciding its
  fate (delete or wire a producer).
- **P4's "M6" disambiguation**: `invalidation.ex:73` comment says "is M6, out of
  scope here" — verified this refers to 20260704's whole-repo M6 (global?
  cross-partition), now tracked as P4. Not this tracker's M6 (destroy-flush-parks).
  P4's inline disambiguation is correct and necessary.
- **Plan A0 repro 20 overload**: M3 (A2) and L4 (A3) both cite "repro 20, X part".
  This is correct — the plan genuinely bundles A2–A5 into one repro slot at
  `plans/…fix-plan.md:118-121`. Awkward at the plan level but the tasks faithfully
  inherit it.
- **L7 dedupe**: `request_headers/1` already lowercases keys and dedupes via
  `Map.new` — the defect is real (no defined precedence) but the current code
  isn't *zero* dedupe. L7's task correctly asks for an explicit precedence rule.
- **deferred-follow-ups RFC**: the referenced
  `docs/design/20260706-atomic-capability-delegation-rfc.md` exists.

---

## Per-task rollup

Compact assessment. "✅" = defect/failure-scenario/fix all verified against
source and feasible; notes only where this pass adds something.

### Blockers
- **B1** ✅ fix feasible (`Info.public_aggregate`/`public_calculation` exist);
  sentinel correction (NotLoaded, not NotSelected) verified against
  `not_loaded.ex:6` + absent `not_selected.ex`.
- **B2** ✅
- **B3** ✅ lead-task ownership correctly designated.
- **B4** ✅ all 3 clauses verified; `external?: true` dead-code status grep-confirmed.
- **B5** ✅ consumer (`value_merge.ex:54-57`) + doc (`data_layer.ex:148`) confirm
  the option holds calc names.
- **B6** ✅
- **B7** ✅

### High
- **H1** ✅ `request_headers/1` exists at `data_layer.ex:414` — fix is threading it.
- **H2** ✅ see §B-3 (fallback note).
- **H3** ✅ `co_commit_repo/3` confirmed at `write.ex:351`.
- **H4** ✅
- **H5** ✅
- **P6** ✅ sweeper's `Enum.each(&Enqueue.flush/2)` error-discard pattern
  (`sweeper.ex:49`) confirmed.

### Medium
- **M1** ✅ crash path through `enqueue_entries(..., record, ...)` confirmed.
- **M2** ✅
- **M3** ✅ defect verified; see §B-1 (fix wording).
- **M4** ✅
- **M5** ✅ correctly subsumed by H3.
- **M6** ✅
- **M7** ✅
- **M8** ✅
- **M9** ✅
- **M10** ✅ spec at `api.ex:392` confirmed malformed vs body.
- **M11** ✅
- **P1** ✅
- **P2** ✅
- **P3** ✅ `sort_references_uncomputable_calc?` at `proven_coverage.ex:471`
  pattern-matches only `%Query{sort: sort}` — no `distinct` field.
- **P4** ✅

### Low
- **L1** ✅ both `[pk] =` sites confirmed (`proven_coverage.ex:410,598`).
- **L2** ✅
- **L3** ✅ see §B-4 (two-half split).
- **L4** ✅
- **L5** ✅
- **L6** ✅
- **L7** ✅ see §C (dedupe is partial, not absent).
- **L8** ✅
- **L9** ✅ `channel.ex:140-141` confirmed.
- **L10** ✅ contradiction confirmed (`write.ex:233` vs live sweeper module).
- **L11** ✅ `write.ex:208` normalize discards `:no_rollback`.
- **L12** ✅ items 3/4/5/8 all fixed-in-tree (verified §A); items 1/2/6/7 open.
- **L13** ✅ item 4 fixed-in-tree (verified §A).

### Release / cross-cutting
- **P5** ✅
- **A0 / R0** ✅
- **FINAL** ✅ self-reference exclusion (spec review's Low) already addressed in
  the file ("all **other** open tasks").
- **deferred-follow-ups** ✅ all referenced files exist; conditional-deferral
  handshake on item 6 is correct.

---

## Strengths worth preserving (this pass's perspective)

- **Provenance is preserved end-to-end**: every task carries its `VERIFIED` vs
  `AGENT` tag, source-review anchor, plan ref, and original-finding ID. This
  pass converted ~20 `AGENT` claims to effectively-`VERIFIED` by hand-checking
  the cited code; the tag system means a future reader knows which were
  independently confirmed and when.
- **The retained-regression list is closed and correct**: all five
  fixed-in-tree items (B1 #27, L12-3/4/5/8) are genuinely present in the current
  working tree, and L13 item 4 is the only docs-only member. The index's count
  ("Five items…") is right.
- **Cross-references survive extraction**: the codebase moved significantly
  since the original findings (e.g. `data_layer.ex` → `proven_coverage.ex` for
  aggregates), and the task files correctly re-map to current locations (P1, L1
  both note the re-extraction and re-verify the new line numbers).
- **Feasibility is non-trivial and confirmed**: H3 depends on `co_commit_repo/3`
  existing (it does, `write.ex:351`); B1 depends on `public_calculation`/
  `public_aggregate` existing (they do, `info.ex:557,620`); H1 depends on
  `request_headers/1` being reusable (it is, `data_layer.ex:414`). No task
  prescribes a fix the code contradicts.

---

## Summary

- Source verifications performed: **~35** (every blocker/high/medium defect
  claim, every fix-feasibility check, every fixed-in-tree assertion, and the
  plan-repro numbering).
- Ship-blocking defects in the task set: **none**.
- Findings raised: **4, all Low** (§B-1 M3 fix wording; §B-2 index status
  workflow; §B-3 H2 fallback note; §B-4 L3 two-half split visibility).
- Recommended action: address §B-1 through §B-4 as one-line task-file edits
  (~10 minutes total), then execute starting with the checkpoint commit (FINAL's
  prerequisite gate) + B1/B2 (security) + the B3-led tenant unit, repro-first
  per A0/R0.
