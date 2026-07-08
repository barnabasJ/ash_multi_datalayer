# Task index: 2026-07-07 second-review fix implementation — open findings

**Source review**:
[`docs/reviews/20260707-second-review-fix-plan-implementation-review.md`](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
**Plan under review**:
[`docs/plans/20260706-second-review-findings-fix-plan.md`](../../plans/20260706-second-review-findings-fix-plan.md)
**Original findings**:
[`docs/reviews/20260706-second-review-findings.md`](../../reviews/20260706-second-review-findings.md)
(#1–#27, A1–A5, B1–B3) **Tracker reviews**: this task set went through seven
review passes, all addressed 2026-07-07 —
[pass 1](../../reviews/20260707-second-review-fixes-task-coverage-review.md)
(F1–F13 → P-tasks, L12/L13, deferred-follow-ups, canonical-tenant decision),
[pass 2a](../../reviews/20260707-second-review-fixes-task-coverage-review-2.md)
(F1–F8 → P6/B3/M9 criteria hardened, gates normalized, rowid item added),
[pass 2b](../../reviews/20260707-second-review-fixes-task-coverage-review-pass2.md)
(verified P-tasks accurate; flagged already-fixed-in-tree items, re-labeled
below; coverage declared complete),
[pass 3a](../../reviews/20260707-second-review-fixes-task-coverage-review-3.md)
(F1–F7 → final-gates task, tracker-hygiene fixes),
[pass 3b](../../reviews/20260707-second-review-fixes-task-coverage-review-pass3.md)
(**sign-off**; checkpoint-commit recommendation, M5-shadow note),
[pass 4a](../../reviews/20260707-second-review-fixes-task-coverage-review-4.md)
(two LOW wording items → fixed), and
[pass 4b](../../reviews/20260707-second-review-fixes-task-coverage-review-pass4.md)
(sign-off), plus two deeper content passes:
[technical review](../../reviews/20260707-second-review-fixes-task-technical-review.md)
(spot-verified 12/12 defect claims against source; 4 LOW — B4 third dead clause,
tenant-unit canonical-function ownership, B5↔P2 posture, index ordering wording)
and
[spec review](../../reviews/20260707-second-review-fixes-task-spec-review.md)
(**1 HIGH: B1's `%Ash.NotSelected{}` acceptance criterion referenced a
nonexistent module — corrected to `NotLoaded`/`ForbiddenField`**; plus mediums
tightening H1/M8/M11/L8/L12-6 acceptance criteria and lows on FINAL/checkpoint/
L5/L6/L7). Then a round-6 pair:
[source-audit](../../reviews/20260707-second-review-fixes-task-source-audit-review.md)
(~35 source verifications incl. all fix-feasibility + fixed-in-tree assertions;
4 LOW — M3 fix wording, `DEFERRED` status, H2 accept-fallback note, L3 two-half
visibility) and
[pass 5](../../reviews/20260707-second-review-fixes-task-review-pass5.md) (4 MED
— index exemption breadth, checkpoint tracked too late → **PRE preflight task**,
M3 after-image contradiction, P6/H5 sequencing trap; 6 LOW), and a round-7 pair:
[holistic review](../../reviews/20260707-second-review-fixes-task-holistic-review.md)
(14/14 source spot-checks exact; 2 WARN — repro-20 disambiguation, **a
cross-cutting tenant-key agreement assertion added to B3** — later scoped by
loop-2/loop-3 to the **four bucketing paths** only, target calls excluded, per
the binding decision below; 5 LOW, 7 INFO) and
[pass 6](../../reviews/20260707-second-review-fixes-task-review-pass6.md) (2
HIGH — **PRE cross-repo commit was mechanically impossible → two per-repo
commits**, and repro-first-per-task made explicit over the step order; 4 MED
tightening H2/M11/M7 + the tenant-consumer→B3 dependency; 4 LOW). All addressed
2026-07-07.

One task file per problem the 20260707 implementation review found **not fixed**
(or newly broken) after two plan runs, plus still-open findings from earlier
reviews. Tasks cover **both repos**: this one (`ash_multi_datalayer`, "MDL") and
the sibling `../ash_remote`. Update the Status column here and the `Status:`
line in the task file as work lands.

Two distinct axes, don't conflate them (holistic review L4): **`Status`**
(below) is workflow state — where the _fix_ is. **`Verification:`** in each task
file (`VERIFIED` = reviewer read the source and confirmed the defect end-to-end;
`AGENT` = traced by a review agent, not independently re-confirmed) is
confidence in the _defect claim_ — it is not a status. Not every task carries a
`Verification:` field (pass-7); where absent, treat it as unspecified. H5 is
`VERIFIED / AGENT` because its sub-claims have mixed provenance.

Statuses: `OPEN` → `IN PROGRESS` → `FIXED (unverified)` → `DONE` (repro test in
suite + full suite green). Also valid: `DEFERRED` (recorded in
[deferred-follow-ups.md](deferred-follow-ups.md)) and `WONTFIX (reason)` (only
with a recorded decision). **Non-behavior tasks** (pass-7): PRE is `DONE` when
its per-repo commits are made **or** a skip is recorded **with the durability
plan** its file requires (loop-2 review: a bare skip does NOT make Cat A fixes
durable, so it does not by itself let downstream retained-regression tasks
close); FINAL and docs-only tasks are `DONE` on their checklist, not a
repro+suite gate.

### Canonical retained-regression inventory (pass-7 — single source of truth)

Supersedes the scattered "five items"/"six items" counts. Three categories, each
keeps or adds a regression test but is **not** held to "must fail on current
code":

- **Cat A — fixed in the _uncommitted_ working tree (this second-plan run;
  commit-fragile, gated by [PRE](pre-checkpoint-commit.md))**: B1's #27 half,
  L12 items 3, 4, 5, 8. (L13 item 4 is also Cat A but docs-only — no test.)
- **Cat B — landed-but-untested from _earlier_ fix runs (already committed; not
  commit-fragile)**: MDL #22 authority verifier, `default_can?` (#20), upsert
  arity guards, **B1's #1 private-_attribute_ half**; ash_remote #6, #9, #10,
  #11, #26, non-string `schema_version`.
- **Cat C — docs-only confirmations**: L13 item 4, L10 doc items, P5 non-runtime
  parts, L9's documentation checkbox (only).

A Cat A/B repro is expected to PASS on the current tree; if one unexpectedly
FAILS, the "fixed" label was wrong — reopen. Cat A additionally depends on PRE.

## Discipline (applies to every task)

Repro-first, per the plan: a **behavior-changing** task is not done until its
new test **fails on the unfixed code for the stated reason**, passes after the
fix, and the touched repo's full suite is green — **MDL:
`INTEGRATION=1 mix test`; ash_remote: `mix test`**. This gate applies to every
behavior fix below even where a task file's checklist is terser. It was skipped
in the last run — zero new test files — and is exactly why B1, B3, B4, B5, B6
shipped looking correct.

**Exemptions from the "must fail on unfixed code" clause** (spec + pass-5
reviews): a retained regression that is **expected to pass on the current
working tree** is still required and kept — it must fail only against a
_historical_ unfixed baseline, not against current code. This covers:

- (a) **items fixed in the uncommitted working tree**: B1's #27 half, L12 items
  3/4/5/8 — a repro that unexpectedly _fails_ means the "fixed" label was wrong,
  so reopen;
- (b) **landed-but-untested work from earlier fix runs that A0/R0/B1 require
  regressions for**: MDL #22 authority verifier, `default_can?` (#20), upsert
  arity guards, and B1's first-run private-attribute (#1) fix; ash_remote #6,
  #9, #10, #11, #26, and the non-string `schema_version` typed error — all
  expected to pass on the current tree;
- (c) **docs-only confirmations**: L13 item 4, the L10 doc items, P5's
  non-runtime parts, and **L9's documentation checkbox only** (L9's
  LifecycleGuard coverage / deferred-follow-up checkbox is NOT docs-only — it
  must still be explicitly closed).

The full-suite gate applies to all of these. None may be rejected for "not
failing first" — that clause binds only genuinely-open behavior fixes.

## Canonical tenant decision (binding for B3/H5/M2/L3/P4)

**Three distinct concepts — do NOT collapse them into one string (loop-2 review,
source-verified).** The bug being fixed is that the _bucketing_ paths disagree
on how they key a tenant; it is NOT that everything should become one string.
Keep these separate:

1. **Canonical partition key** — the value that buckets a tenant in the
   **ledger/coverage, write invalidation, outbox chain filters, and
   notification** paths. ONE shared function derives it from any tenant
   representation (struct via `Ash.ToTenant`, integer/uuid/atom attribute value,
   string). These four paths MUST agree via that one function; no ad-hoc
   `inspect`/`to_string`. Integer/atom → string via `to_string/1`
   (`:foo → "foo"`, `42 → "42"`), never `inspect/1`.
2. **Unscoped scope sentinel** — a distinct value meaning "all partitions" for
   scans. **B3 pins it** (reconciling coverage's `:__global__` with H5's `:all`
   into ONE sentinel; never `nil`); H5 is its main consumer. A scope marker, not
   a tenant.
3. **Target-call tenant value** — the actual Ash tenant passed to the
   **delegated layer's** Ash calls: the push at `flush.ex:167-178`
   (`Target.upsert`/`Target.destroy`) **AND the separate stale-check read at
   `flush.ex:196` (`Target.read_pk(..., tenant: entry.tenant)`)** (loop-5: don't
   thread only the push and miss the stale-check read), plus Backfill — e.g.
   `tenant: entry.tenant`. This must stay a **real tenant value the target layer
   understands** (via `Ash.ToTenant`/`set_tenant`), NOT the partition-key string
   and NOT the sentinel. It must be _derived consistently_ from the same source
   tenant, but forcing it to the partition string would break tenancy on the
   target.

**B3 is the lead** (technical review F2): it creates and commits the partition-
key function (concept 1) first **and pins the single unscoped sentinel value
(concept 2)** as one of its normalization rules — so `:__global__` (coverage)
and the LocalOutbox scan sentinel are reconciled in one place. H5/M2/L3/P4
**consume** both verbatim and cite B3 as a dependency rather than re-deriving a
helper; H5 is the primary _consumer_ of the sentinel (for its scan scope) but
does not own it (loop-3: single owner = B3). Target-call threading (concept 3)
is H5/#19 work and uses the real tenant, not the partition key.

## Blockers

| ID  | Task                                                                                                          | Repo       | Status |
| --- | ------------------------------------------------------------------------------------------------------------- | ---------- | ------ |
| B1  | [RPC exfiltrates private calcs/aggregates + field-policy 500](b1-rpc-private-calc-aggregate-exfiltration.md)  | ash_remote | DONE   |
| B2  | [Aggregate-filter code injection at codegen](b2-aggregate-filter-codegen-injection.md)                        | ash_remote | DONE   |
| B3  | [`tenant_from_filter/2` dead code — attribute-tenancy invalidation inert](b3-tenant-from-filter-dead-code.md) | MDL        | DONE   |
| B4  | [ExternalChange origin marker matches no real notification](b4-external-change-origin-marker-mismatch.md)     | MDL        | DONE   |
| B5  | [`validate_aggregate_overrides` compile regression](b5-validate-aggregate-overrides-regression.md)            | MDL        | DONE   |
| B6  | [Stale-check payload compare skips JSON normalization](b6-stale-check-json-normalization.md)                  | MDL        | DONE   |
| B7  | [Resolution-verb guard inverted for `:synced` entries](b7-resolution-verb-synced-guard.md)                    | MDL        | DONE   |

## High

| ID  | Task                                                                                                      | Repo       | Status |
| --- | --------------------------------------------------------------------------------------------------------- | ---------- | ------ |
| H1  | [Bundled remote-calculation fetch runs unauthenticated](h1-remote-calc-fetch-unauthenticated.md)          | ash_remote | DONE   |
| H2  | [Non-PK upsert identity ignored + accept-list truncation](h2-non-pk-upsert-identity-accept-truncation.md) | ash_remote | DONE   |
| H3  | [`refresh/3` TOCTOU vs co-committed local write](h3-refresh-toctou.md)                                    | MDL        | DONE   |
| H4  | [`write_through` drain race + post-target-push divergence](h4-write-through-drain-race-divergence.md)     | MDL        | DONE   |
| H5  | [LocalOutbox tenant model: `nil` = "IS NULL" vs "unscoped"](h5-localoutbox-nil-tenant-model.md)           | MDL        | DONE   |
| P6  | [Lost-kick recovery semantics (#4): sweeper unproven](p6-lost-kick-recovery.md)                           | MDL        | DONE   |

## Medium

| ID  | Task                                                                                                                                         | Repo       | Status |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------- | ---------- | ------ |
| M1  | [`{:upsert_skipped, ...}` crashes with `BadMapError`](m1-upsert-skipped-badmaperror.md)                                                      | MDL        | DONE   |
| M2  | [Context-tenancy invalidation uses raw metadata tenant](m2-context-tenancy-raw-metadata-tenant.md)                                           | MDL        | DONE   |
| M3  | [External update passes after-image as `row_before`](m3-external-update-after-image-row-before.md)                                           | MDL        | DONE   |
| M4  | [`discard_local/1` destroys freshly re-read chain, skips head guard](m4-discard-local-chain-destroy.md)                                      | MDL        | DONE   |
| M5  | [Refresh/delete reconciliation not atomic with dirty check](m5-refresh-delete-reconciliation-not-atomic.md) — subsumed by H3, closes with it | MDL        | DONE   |
| M6  | [Destroy-flush of already-gone row parks as `:rejected`](m6-destroy-flush-already-gone-parks.md)                                             | MDL        | DONE   |
| M7  | [Query calculations/aggregates decoded uncast](m7-query-calc-aggregate-decode-uncast.md)                                                     | ash_remote | DONE   |
| M8  | [Changeset-less multitenant broadcast unjoinable](m8-changeset-less-multitenant-broadcast.md)                                                | ash_remote | DONE   |
| M9  | [`discard`/`drop_chain` not inside co-commit transaction](m9-discard-drop-chain-not-transactional.md)                                        | MDL        | DONE   |
| M10 | [`hydrate/2` wraps `{:error, _}` refresh in `{:ok, ...}`](m10-hydrate-wraps-error.md)                                                        | MDL        | DONE   |
| M11 | [Client decoder crashes on `nil`/single-object responses](m11-decoder-crashes-nil-single-object.md)                                          | ash_remote | DONE   |
| P1  | [Source-computed aggregate guard bypassed on non-merged paths](p1-aggregate-guard-bypass.md)                                                 | MDL        | DONE   |
| P2  | [Verifier rejections don't block plain `mix compile`](p2-verifier-compile-posture.md)                                                        | MDL        | DONE   |
| P3  | [Uncomputable-calc guard misses `distinct`/`distinct_sort`](p3-distinct-uncomputable-guard.md)                                               | MDL        | DONE   |
| P4  | [`global? true` invalidation never crosses partitions](p4-global-tenant-invalidation.md)                                                     | MDL        | DONE   |

## Low

| ID  | Task                                                                                                                               | Repo       | Status |
| --- | ---------------------------------------------------------------------------------------------------------------------------------- | ---------- | ------ |
| L1  | [Composite-PK crash in aggregate fold paths](l1-composite-pk-aggregate-paths.md)                                                   | MDL        | DONE   |
| L2  | [Aggregate fold leaves `%Ash.NotLoaded{}` (flaky live test)](l2-aggregate-fold-notloaded.md)                                       | MDL        | DONE   |
| L3  | [`write_through` inline drain misses creates; nil tenant on attribute-tenancy creates](l3-write-through-drain-create-pk-tenant.md) | MDL        | DONE   |
| L4  | [String/CiString range subsumption still byte-ordered](l4-string-range-subsumption-collation.md)                                   | MDL        | DONE   |
| L5  | [Sweeper `{:global, ...}` name fails second-node boot; RejectMultiNode config](l5-sweeper-global-name-multinode.md)                | MDL        | OPEN   |
| L6  | [Codegen LOWs: identifier validation, path traversal, FK fidelity](l6-codegen-lows.md)                                             | ash_remote | OPEN   |
| L7  | [Data-layer LOWs: header dedupe, write retries, composite PK, sort args](l7-data-layer-lows.md)                                    | ash_remote | OPEN   |
| L8  | [RPC dispatch lacks explicit `authorize?: true`](l8-rpc-authorize-flag.md)                                                         | ash_remote | OPEN   |
| L9  | [Undecidable destroy notifications dropped — document staleness class](l9-destroy-notification-drop-docs.md)                       | ash_remote | OPEN   |
| L10 | [Doc/code contradictions introduced by this work](l10-doc-code-contradictions.md)                                                  | MDL        | OPEN   |
| L11 | [`{:error, :no_rollback, _}` signal discarded by normalization](l11-no-rollback-signal-discarded.md)                               | MDL        | OPEN   |
| L12 | [MDL misc LOWs: ETS rescue, dedupe key, capability probe, stale-check gaps, pruning](l12-mdl-misc-lows.md)                         | MDL        | OPEN   |
| L13 | [Server/realtime LOWs: manifest auth, revocation docs, refetch amplification](l13-ash-remote-server-realtime-lows.md)              | ash_remote | OPEN   |

## Release readiness (older, still open)

| ID  | Task                                                                 | Repo | Status |
| --- | -------------------------------------------------------------------- | ---- | ------ |
| P5  | [`mix hex.build` fails; package metadata missing](p5-hex-package.md) | MDL  | OPEN   |

## Cross-cutting

| ID    | Task                                                                                              | Repo       | Status |
| ----- | ------------------------------------------------------------------------------------------------- | ---------- | ------ |
| PRE   | [Checkpoint-commit the uncommitted working tree](pre-checkpoint-commit.md) — **do FIRST**         | both       | OPEN   |
| A0    | [Build the MDL repro/regression harness the plan mandates](a0-mdl-repro-harness.md)               | MDL        | OPEN   |
| R0    | [Build the ash_remote repro/regression harness the plan mandates](r0-ash-remote-repro-harness.md) | ash_remote | OPEN   |
| FINAL | [Plan final gates: demo exercise, docs sweep, closure checks](final-gates.md) — last to close     | both       | OPEN   |

Deliberately parked items (with reasons) live in
[deferred-follow-ups.md](deferred-follow-ups.md) — including the first plan's
explicit M-7/M-12 exclusions. Nothing outside these tables and that file is open
— and the tracker itself is not closed until [final-gates.md](final-gates.md) is
done (the plan's completion bar: demo exercise, docs sweep, changelog
reconciliation).

## Recommended order (from the review)

**Binding rule that overrides the step numbering** (pass-6 review): for every
behavior-changing task, its failing A0/R0 repro is written and confirmed to fail
**before** that task's fix — repro-first is per-task, not per-phase. The
numbered steps below are _fix dependency priority_; A0/R0 appearing at step 4
does NOT mean "write no repros until step 4." A0/R0 as tracker tasks close later
(once every task's repro plus the retained regressions exist), but each
individual repro lands with — and before — its own fix.

0. **PRE** — checkpoint-commit the uncommitted tree (guards the fixed-in-tree
   items before any retained-regression work touches them).
1. Security holes: **B1**, **B2**.
2. Tenant model as one unit: **B3 + H5 + M2 + P4** (plus L3's tenant half) — the
   canonical-tenant decision above is binding.
3. **B4**, **B5**, **B6**, **B7**.
4. **A0/R0** harness — the control that would have caught B1/B3/B4/B6.
5. Remaining HIGH (H1–H4, P6), then MED (incl. P1–P4), then LOW; P5 before any
   Hex release.

A0/R0 at step 4 reflects **dependency priority, not a harness deferral**
(technical review F4): the harness is built incrementally alongside each fix,
repro-first per task, from step 1 onward — do not batch it after step 3.

**L3 has two halves** (source-audit B-4): the _tenant_ half (part of step 2's
unit) and a _create-PK drain_ half in `write_through` that coordinates with
**H4** in step 5 (same function). Working the tenant half in step 2 and leaving
the drain half for H4 is fine — just don't lose the drain half.

Pairing note (pass-2b review): land **P1 + L2 together** — both add
aggregate-resolved guards in `proven_coverage.ex`; coordinate so the guards
compose instead of duplicating.

Retained-regression items are enumerated in the **Canonical retained-regression
inventory** above (Cat A uncommitted-fixed-in-tree, Cat B landed-but-untested,
Cat C docs-only) — that table is the single source of truth. For **Cat A/B
behavior regressions**, write each repro, expect it to PASS, keep it, and reopen
if one unexpectedly fails. **Cat C is docs-only — no repro** (loop-6: the "write
each repro" instruction applies to A/B only; L13 item 4, L10 doc items, P5
non-runtime parts, L9's doc checkbox are confirmed, not tested).

⚠ **Commit-fragility (pass-3b §A)**: all of these are fixed only in the
**uncommitted** working tree — a `git checkout`/branch switch silently reverts
them with nothing to catch it. This is owned by the
**[PRE](pre-checkpoint-commit.md) preflight task (step 0, do FIRST)** — the
checkpoint commit must happen before any retained-regression work touches those
files, which is why it's a preflight and not only the FINAL gate (pass-5 review:
FINAL alone tracked it too late).

## Context

- The committed history is the _first_ fix plan (whole-repo findings M-1…M-12 /
  R-1…R-11) — done and green **except** the handoff's explicit exclusions:
  M-12's declared follow-up tests and the M-7 fix beyond documentation, both
  recorded in [deferred-follow-ups.md](deferred-follow-ups.md).
- The _second_ plan's partial implementation exists only as an **uncommitted
  working tree** (plus untracked `lib/ash_multi_datalayer/tenant_key.ex` and
  `lib/ash_multi_datalayer/orchestrator/local_outbox/sweeper.ex`, and
  uncommitted `../ash_remote` `lib/` changes). Do not treat it as landed; some
  of its "fixes" are inert (B3, B4, B6) or regressive (B5, B7).
- What DID land soundly (keep, don't re-do): ProvenCoverage core solver + epoch
  protocol, plan-A2 dispatch/normalization, plan-A6 NotLoaded filtering +
  401/403 classify, #2/A1 eviction, the #22 authority-order verifier
  (`validate_layers.ex:146-157` — landed but **untested**; A0 must retain a
  regression test), and in ash_remote #6, #9, #10, #11, #26, non-string
  `schema_version` errors, plus 20260704 M3's `aggregate_filter` clean refusal
  (`can?` false). Oban double-enqueue is a non-issue.
