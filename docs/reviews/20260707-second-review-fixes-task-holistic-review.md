# Holistic review — `docs/tasks/20260707-second-review-fixes/`

- **Reviewer**: opencode (automated)
- **Date**: 2026-07-07
- **Scope**: every task file in `docs/tasks/20260707-second-review-fixes/` — the
  `00-index.md`, all 46 task entries (PRE, A0, R0, FINAL; B1–B7; H1–H5, P6;
  M1–M11, P1–P4; L1–L13; P5) and `deferred-follow-ups.md`.
- **Method**: full read of every task file + index + deferred list; source
  spot-verification of the highest-stakes defect claims and the "fixed-in-tree"
  assertions against the current working trees of both MDL and `../ash_remote`;
  cross-check of the index tables against the files, the cross-references
  between tasks, the repro numbering, and the recommended order.

This is a review of the **task documents** (accuracy, consistency, completeness,
actionability, sequencing), backed by source spot-checks — not a re-derivation
of every finding or a code change.

## Verification summary (source spot-checks)

The following defect / "fixed-in-tree" claims were checked against the current
working tree. **Every one matched the task file's description, at the cited
locations.**

| Task | Claim verified | Location | Result |
| ---- | -------------- | -------- | ------ |
| B1 | `aggregate?`/`calculation?` use non-public `Info.aggregate`/`Info.calculation` while `attribute?`/`relationship?` use `public_*`; `value/1`+`loaded/1` map `NotLoaded`/`ForbiddenField`→nil | `../ash_remote/lib/ash_remote/server/fields.ex:97-102,132-135` | ✅ exact |
| B2 | `aggregate_block` splices `field.aggregate_filter` raw into `filter expr(...)`; `reproducible_aggregate?/1` only checks `relationship`, no `safe?` gate | `../ash_remote/lib/ash_remote/gen/generator.ex:361-375` | ✅ exact |
| B3 | `tenant_from_filter/2` regex-parses `inspect(filter, limit: :infinity)`; attribute write-side returns raw typed `Map.get(record, attr)` (no string canonicalization) | `lib/ash_multi_datalayer/tenant_key.ex:44-73` (untracked) | ✅ exact |
| B4 | three positive `replayed_external?` clauses (str/str, atom/atom, `external?: true`) | `lib/ash_multi_datalayer/notifiers/external_change.ex:72-81` | ✅ exact |
| B5 | `validate_aggregate_overrides` validates `local_evaluation_overrides` (calc names) against `aggregate_names` | `lib/ash_multi_datalayer/verifiers/validate_aggregate_overrides.ex:29-40` | ✅ exact |
| B6 | `remote_matches_payload?` compares `Snapshot.dump(host, remote) == entry.payload` with no `json_scalar`, while `stale_check` (199-217) does normalize | `lib/ash_multi_datalayer/orchestrator/local_outbox/flush.ex:231-234` | ✅ exact |
| B7 | `ensure_resolvable_head` returns `:ok` for `state == :synced`, falling into the `with` body | `lib/ash_multi_datalayer/orchestrator/local_outbox/api.ex:603-621` | ✅ exact |
| H2 | `upsert/3` ignores `keys` (`_keys`); `accepted_keys/1` falls back to all attrs only when `action.accept` is unset | `../ash_remote/lib/ash_remote/data_layer.ex:198,367-371` | ✅ exact |
| L12-3 | `simple_expression` handled in `capability.ex` | `lib/ash_multi_datalayer/capability.ex` | ✅ fixed-in-tree |
| L12-4 | supervisor filters `resources:` by `multi_datalayer?/1` on both branches | `lib/ash_multi_datalayer/supervisor.ex:62,68` | ✅ fixed-in-tree |
| L12-5 | stale-check returns `{:conflict, nil}` for `:update` with base_image when remote missing | `lib/ash_multi_datalayer/orchestrator/local_outbox/flush.ex:199-203` | ✅ fixed-in-tree |
| L12-8 | `enqueue.ex` includes `"write_ref" => entry.write_ref` in job args | `lib/ash_multi_datalayer/sync/enqueue.ex:31` | ✅ fixed-in-tree |
| L13-4 | `connect_params` doc comment updated (R-9 correction) | `../ash_remote/lib/ash_remote/realtime/connection.ex:29` | ✅ fixed-in-tree |
| — | `sweeper.ex` exists but is untracked | `lib/ash_multi_datalayer/orchestrator/local_outbox/sweeper.ex` | ✅ untracked, as index says |

**Takeaway**: the task set's source fidelity is high. The blocker/high claims
that were checkable line up precisely. The "fixed-in-tree" labels (which gate
the retained-regression exemptions) are all accurate against the current tree —
those exemptions are safe to rely on.

## Coverage / completeness

- **Index ↔ files bidirectional match**: every ID in the index tables (B1–B7,
  H1–H5, P6, M1–M11, P1–P4, L1–L13, P5, PRE, A0, R0, FINAL) has a file; every
  file maps to exactly one table row; no orphan files, no missing files. 48
  files total (46 task entries + deferred list + index).
- **Deferred list is coherent**: items 1–8 + separate arcs are not duplicated in
  the open tables; the two cross-referenced deferrals (item 5 ↔ L13, item 6 ↔
  L13 item 3) are consistent in both directions, including item 6's
  conditional-deferral rule (do not pre-defer before L13-3 measures).
- **M5 subsumption**: index, M5, and H3 all agree M5 closes with H3 and is not
  independently worked. Consistent.
- **First-plan handoff exclusions (M-7, M-12)** are present in deferred items
  7–8 and explicitly excluded from "M-1…M-12 done". Not lost.

## Findings

Severity scale: **CRITICAL** (blocks acting on the tasks) · **WARNING** (should
fix before/during work) · **LOW** (wording / hygiene) · **INFO** (observation).

### WARNING

#### W1 — Repro 20 is claimed by two tasks (M3 + L4) with no disambiguation
`m3-…:50` says "plan A0 repro 20, A2 part" (filter-movement / after-image as
`row_before`); `l4-…:28` says "plan A0 repro 20, A3 part" (string range
subsumption). The index says A0 has "20 named failing repros." Either:
- repro 20 is one test with two scenario parts (in which case M3 and L4 should
  say so and name the shared file so they don't each write a separate "repro 20"),
  or
- this is a numbering collision and one of them should be renumbered.

Today both task-doers would independently write "the repro 20" and one would
silently clobber the other. **Pick one and make both tasks cite the
resolution.**

#### W2 — No single test asserts all five canonical-tenant paths agree
The index's binding decision says *every* path — read coverage, write
invalidation, outbox chain filters, notifications, target calls — must call the
one canonical function. B3 owns creating it and its "Representation test"
checkbox asserts read-side and write-side produce the same key. But outbox chain
filters, notifications, and target calls (the other three consumers: H5, M2, L3,
P4) each only test their own path. If any one consumer subtly diverges on an
edge case (e.g. a struct tenant whose `Ash.ToTenant` differs from
`Map.get(record, attr)`), the per-task repros can all pass while cross-path
invalidation still silently misses.

**Add (to B3, as lead) one cross-cutting assertion**: for a fixed tenant input
across all representations (struct, integer, atom, string, converted), all five
call sites return the identical canonical key. This is the one test that catches
a five-way divergence their individual repros miss — exactly the failure class
the "binding decision" exists to prevent.

### LOW

#### L1 — H5 presupposes the `:all` sentinel while the binding decision defers it to B3
`h5-…:42` ("Fix") says "an explicit `:all` sentinel," but the index's binding
decision and `b3-…:72-74` say **B3 picks** the single unscoped sentinel
(reconciling read-side `:__global__` with H5's proposed `:all`). H5 should read
"the sentinel chosen by B3," not presuppose `:all`. Small, but if H5 is worked
first it would pre-empt B3's decision.

#### L2 — B3's "Related tasks" omits P4 from the tenant unit
The index's tenant unit is "B3 + H5 + M2 + P4 (plus L3's tenant half)."
`b3-…:12-15` lists H5/M2/L3 but **not P4**; P4 reciprocally lists B3/H5/M2. Add
P4 to B3's Related-tasks block for symmetry (and so a B3-doer knows P4 consumes
the function).

#### L3 — P6 ↔ L5 reciprocal link is one-directional
P6 lists L5 as related (same `sweeper.ex` module: recovery semantics vs global
name). L5 does not list P6. Minor, but they touch the same untracked module and
a fix to one can perturb the other.

#### L4 — Index conflates two axes under similar names: `Status` vs `Verification`
The index defines a `Status` taxonomy (OPEN → IN PROGRESS → FIXED (unverified) →
DONE) but task files also carry a `Verification:` field (VERIFIED / AGENT /
none). These are distinct (workflow state vs defect-claim confidence) and are
used consistently, but a one-line gloss in the index distinguishing them would
prevent a doer from reading "AGENT" as a status.

#### L5 — M9 carries an unverified conditional that can expand its scope
`m9-…:23-27` folds rebase-cleanup (plan A5 item 8) into scope *if*
`destroy_captured_chain`'s `transaction!` is `Ash.DataLayer.transaction` (a
no-op on AshSqlite). The task correctly flags this for verification, but it
means M9's scope is not finally known until that check runs. Acceptable as
written (it's explicitly called out), just note it during sizing.

### INFO (no action required — recorded for confidence)

- **I1 — AGENT-verified items carry residual risk.** Most ash_remote and LOW
  defect claims are tagged `Verification: AGENT` (traced by the review agent, not
  independently re-confirmed against source). I independently re-checked two
  AGENT items (B2, H2) and two VERIFIED items in the sibling repo; all four were
  accurate. This raises confidence in the AGENT set, but the AGENT-tagged LOWs
  (L3–L13) are the ones most likely to hold a surprise line-number drift —
  re-map file:line at the start of each (the tasks already instruct this for
  post-extraction files).
- **I2 — B3's "always returns nil" is slightly overstated but the fix is
  unaffected.** Whether `tenant_from_filter/2` returns nil depends on the
  inspected filter representation; the unsoundness (regex-on-inspect; raw-typed
  write-side key; no canonicalization) is real and verified. The proposed fix
  (structural AST walk + shared canonical function) is correct regardless of how
  often the current regex happens to miss.
- **I3 — Discipline exemptions are dense but redundantly restated.** The index's
  "Exemptions from must-fail-first" block is correct and each exempted task
  (B1, L9, L12, L13) re-states its own exemption. Good defensive redundancy;
  not a defect.
- **I4 — PRE correctly owns the commit-fragility risk.** Everything "fixed" is
  only in the uncommitted working tree (verified: large `git status` in both
  repos, plus untracked `tenant_key.ex` + `sweeper.ex`). PRE at step 0 and FINAL
  only confirming is the right structure; the pass-5 promotion from a FINAL-only
  gate to a preflight was correct.
- **I5 — L2's flaky-live-test gate is well-designed.** The deterministic repro
  is primary; the 20×-pass live loop is explicitly supplementary. This is the
  right call (a flaky-test-only gate isn't measurable on its own).
- **I6 — M8 / L9 "observable signal" hardening is present and consistent.**
  Both were tightened (spec review) to forbid docs-only closure and require an
  observable reconcile/gap signal; the index's exemption list explicitly excludes
  L9's LifecycleGuard checkbox from docs-only treatment. The hardening is
  consistent across all three sites.
- **I7 — B5↔P2 posture dependency is correctly bounded.** B5's repros assert via
  `verify/1` directly (not plain `mix compile`) and B5 notes its rejection
  guarantee is bounded by P2. Sound.

## Sequencing / dependencies

The recommended order is sound and the dependency graph is acyclic:

- **PRE (step 0) → everything** — correct; verified all fixed-in-tree items are
  uncommitted, so PRE genuinely gates the retained-regression tasks.
- **B3 leads the tenant unit** — H5/M2/L3/P4 all cite B3 as the dependency and
  all say "consume verbatim" / "same function as B3." No task re-derives a
  canonical helper. Consistent with the binding decision. (See W2 for the one
  gap in this otherwise clean unit.)
- **A0/R0 at step 4** is explicitly *not* a harness deferral (index addresses
  this directly: "built incrementally alongside each fix, repro-first"). A0's own
  file repeats it. No deferral risk.
- **B1/B2 first (security)**, then tenant unit, then B4–B7, then harness, then
  HIGH/MED/LOW — defensible priority ordering.
- **P1 + L2 pairing note** (both add aggregate guards in `proven_coverage.ex`)
  is called out in the index. Good coordination flag.

No task's "Done when" depends on a later-step task in a way that creates a
cycle. M5 depends on H3 (same step family); M9's rebase-cleanup dependency is
internal (L5).

## Actionability of "Done when" criteria

Strong overall. Every behavior-changing task has a fail-first repro checkbox
with the specific unfixed-code failure mode named, plus a positive/retained
regression checkbox where relevant. Specific hardenings worth calling out as
exemplary:

- **B1**: distinguishes the fail-first #1 repro from the retained #27 regression
  (expected to PASS), and explicitly forbids a `%Ash.NotSelected{}` test case
  (nonexistent module — corrected in the spec review).
- **B3**: includes the zero-row repro (pass-2 F3) and the multi-predicate / `or`
  / `in` filter cases.
- **B2 / L6**: separate loader-pass-through vs generator-safety-gate assertions,
  and traversal repros must run in a temp output root.
- **M8 / L9 / L13-3**: require observable signals and measured numbers, not
  docs-only closure.

The one actionability gap is **W2** (no cross-cutting canonical-key assertion).

## Verdict

The task set is **ready to execute** after the two WARNING items are resolved.
Source fidelity is high (14/14 spot-checks exact), the index and files are
mutually consistent, the deferred/parked boundary is clean, the dependency graph
is acyclic, and the "Done when" criteria are testable and fail-first where
required.

**Counts**: 0 CRITICAL · 2 WARNING · 5 LOW · 7 INFO.

### Recommended edits before work begins

1. **W1** — disambiguate repro 20 in `m3-…md` and `l4-…md` (shared file, or
   renumber one).
2. **W2** — add a cross-cutting "all five paths agree on the canonical key"
   assertion to B3's "Done when."
3. **L1** — change H5's `:all` to "the sentinel chosen by B3."
4. **L2** — add P4 to B3's Related-tasks block.
5. **L3** — add P6 to L5's Related-tasks block (reciprocate).
6. **L4** — add a one-line gloss to the index distinguishing `Status` from
   `Verification:`.

W1 and W2 should be resolved before the tenant unit / A0 repro work touches them;
L1–L4 are wording fixes that can ride the next docs sweep (but L1 should land
before H5 is picked up).
