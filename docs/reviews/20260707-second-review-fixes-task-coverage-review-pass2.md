# Review (pass 2): task coverage for `20260707-second-review-fixes/`

**Date**: 2026-07-07 (second pass)
**Subject**: re-review of the task set after the author responded to
[`20260707-second-review-fixes-task-coverage-review.md`](20260707-second-review-fixes-task-coverage-review.md)
(pass 1, findings F1–F13).
**What changed**: the author added `deferred-follow-ups.md`, `L12`, `L13`, six
`P`-tasks (P1–P6), a binding canonical-tenant decision block, credited #22, and
amended several acceptance criteria.
**Method**: read every new/changed file; re-verified each new claim and each
"already-fixed?" question against source.

---

## Verdict

**Coverage is now effectively complete — pass 1's central concern is resolved.**
Every finding from all three prior reviews (second-review #1–#27/A1–A5/B1–B3 +
LOWs; first-review M-1…M-12/R-1…R-11; the 20260704 review's M2/M4/M5/M6/R1) now
has a tracked home: an open task, a verified-fixed credit, or a deferred-with-
reason entry. The index's closure claim ("Nothing outside these tables and that
file is open") is now **defensible**.

The new `deferred-follow-ups.md` is exactly the right fix for the "deferred →
forgotten" failure mode pass 1 flagged — it captures all 6 plan-deferred items
**and** the first-plan's M-7/M-12 exclusions, so "done" can no longer be misread
as "nothing remains." P6 independently catches a real bug in the source review
itself (the impl review **mislabeled #4 as "external-change"** — #4 is lost-kick
recovery; external-change is #21/B4), which protects that requirement from
falling through a third time.

**One new systemic issue**: the author treated **5 findings that are already
fixed in the uncommitted working tree as OPEN**, each with a "fails on unfixed
code" repro that will in fact **pass immediately**. This will confuse
implementers ("my failing repro passes") and burn verification cycles. These
need re-labeling to "DONE — retain regression test" or an explicit "verify,
likely already fixed" note. Details in §A.

**One minor carryover** from pass 1: H3 still doesn't cover the
`delete_local_pk/3` raise (§B).

---

## A. Already-fixed findings mislabeled OPEN  *(the main actionable)*

Each of these has its fix already present in the working tree. The "fails on
unfixed code" repro in the task will not fail.

| Task | Item | Evidence it's already fixed |
|------|------|------------------------------|
| **B1** (#27 half) | ForbiddenField/NotSelected → nil in serialization | `fields.ex:97-102` maps `%Ash.ForbiddenField{}` **and** `%Ash.NotLoaded{}` to nil in both `value/1` and `loaded/1`; `serialize` routes through them (`:78,:91`). Part of the **63-line uncommitted diff** vs `f8a1b67`. The Jason 500 cannot occur. B1's done-when "#27 repro fails on unfixed code with the Jason crash" is stale. |
| **L12** item 3 | `Capability.collect/2` skips `simple_expression` | `capability.ex:38` `in_vm_evaluable?(…{simple_expression: {:ok,_}})` and `:56` `custom.simple_expression` — handled. |
| **L12** item 4 | Supervisor `resources:` not filtered by `multi_datalayer?` | `supervisor.ex:62,68` both `Enum.filter(…, &multi_datalayer?/1)`. |
| **L12** item 5 | stale-check missing-remote = no-conflict (UPDATE resurrect) | `flush.ex:199-203` already returns `{:conflict, nil}` for `op==:update and not is_nil(base_image)`. (L12 hedged "verify current status" — verified: fixed.) |
| **L13** item 4 | stale `connect_params` doc contradicts R-9 fix | `connection.ex:29` and `:170` are now consistent ("evaluated once per connection in init/1"). |

**Recommended action**: re-label these five as `DONE (unverified)` with a single
"retain a regression test" checklist item each (the A0/R0 harness is the natural
home), or add an explicit "⚠ likely already fixed in the working tree — write
the repro; if it passes on unfixed code, convert to a regression test" note.
L12's done-when ("fix, or move to deferred with a reason") doesn't contemplate
"already done" and will otherwise stall on a no-op verification.

The calc/aggregate half of B1 (#1) is **genuinely open** (`fields.ex:133-134`
use `Info.aggregate`/`Info.calculation`) — that half is correct as written.

---

## B. Minor carryover: H3 still omits `delete_local_pk/3` raise

`api.ex:386-388` `delete_local_pk/3` **raises** on `{:error, reason}` during
refresh-delete reconciliation. H3's done-when covers `reconcile_deletes`
returning a structured error instead of a `MatchError`, but not this sibling
raise — which is the same #18 "no raise/`MatchError` on a read failure" contract.
Fold `delete_local_pk/3` into H3's third done-when bullet (one clause addition:
`{:error, _} = e -> e`). Low impact (rare path) but it's the clean place to land
it.

---

## C. New P-tasks — verified accurate

I verified each P-task's source claims; all are real and correctly scoped.

- **P1** ✅ — `ensure_source_aggregates_resolved!` is called at **exactly one
  site** (`proven_coverage.ex:629`, merged-read branch); the cold-cache /
  kill-switch / non-mergeable / single-layer branches are unguarded. Correct.
- **P2** ✅ — verifier-downgrade posture is real and **well-noted** that it
  weakens B5 and the #22 verifier (both compile-as-warning under plain
  `mix compile`). Good cross-link.
- **P3** ✅ — `sort_references_uncomputable_calc?/3` (`proven_coverage.ex:471`)
  pattern-matches only `%Query{sort: sort}`; `distinct`/`distinct_sort` are
  replayed (`:803-804`) but not guarded. Confirmed.
- **P4** ✅ — `invalidation.ex:72-73` comment explicitly defers the
  cross-partition sweep ("…is M6, still open"). Confirmed; correctly folded into
  the tenant unit.
- **P5** ✅ — Hex packaging; out of behavioral scope, correctly sequestered as
  "release readiness."
- **P6** ✅ — addresses pass-1 G1 (the #4 discarded-error half). Correctly
  requires proving the sweeper closes the lost-kick window rather than assuming
  it. **Bonus**: documents the source-review #4/#21 mislabel.

No P-task duplicates an existing task. P1/L2 are the same family (aggregate
guards in `proven_coverage.ex`) but distinct paths — P1 already flags the
coordination need ("compose rather than duplicate"); recommend landing them
together to avoid two passes over the same file.

---

## D. Pass-1 gaps — disposition

| Pass-1 gap | Status now |
|------------|------------|
| G1 (#4 discarded-error half) | ✅ **P6** |
| G2 (B1/#27 split) | ⚠️ split done, but #27 half mislabeled open (§A) |
| G3 (`Coverage.insert` rescue) | ✅ **L12** item 1 |
| G4 (`dedupe_key` phash2) | ✅ **L12** item 2 |
| G5 (6 deferred items) | ✅ **deferred-follow-ups.md** (+ M-7/M-12 bonus) |
| G6 (2 doc LOWs) | ✅ **L12** item 6 + **L13** item 1 |
| G7 (`:synced` pruning) | ✅ **L12** item 7 |
| G-adjacent (`delete_local_pk` raise) | ⚠️ still not in H3 (§B) |

7 of 8 fully resolved; the remaining two are the §A mislabel and the §B carryover.

---

## E. Coverage check — is anything still untracked?

I re-walked all three review sources against the current tables + deferred file:

- **Second review**: all 34 HIGH/MED/letter findings → tasked or verified-fixed.
  All ~30 LOWs → L6/L7/L12/L13 batches + L1–L11 + deferred. No orphans.
- **First review** (M/R): committed, with M-7/M-12 exclusions now explicitly in
  `deferred-follow-ups.md`. No orphans (M-7's "document only" status is now
  recorded as still-open-by-design).
- **20260704 review**: P1–P5 pull forward M2/M4/M5/M6/R1. No orphans.

The closure claim holds. The single untracked behavioral item is the §B
`delete_local_pk` raise (a scope gap within an existing task, not an orphan).

---

## Recommendations

1. **Re-label the 5 already-fixed items** in §A (B1/#27, L12 #3/#4/#5, L13 #4)
   to `DONE (unverified)` + "retain regression test," or add the "⚠ likely
   already fixed" note. This is the one change that prevents implementer
   confusion.
2. **Add `delete_local_pk/3` to H3's** third done-when bullet (§B).
3. **Land P1 + L2 together** — both add aggregate-resolved guards in
   `proven_coverage.ex`; coordinate so they compose.
4. Otherwise: **the set is ready to execute.** The repro-first gate (A0/R0)
   remains the load-bearing control — every task closes only when its repro
   fails on unfixed code first, which is exactly what will surface any remaining
   "already fixed / actually open" misclassifications at implementation time.

---

## Summary

- Pass-1 gaps: **7/8 resolved**; 1 minor carryover (§B).
- New P-tasks: **6/6 verified accurate**.
- New issue: **5 already-fixed findings mislabeled OPEN** (§A) — the one thing to
  fix before execution begins.
- Coverage: **complete** — every finding across all three reviews has a tracked
  home. The "things left undone" risk the user named is now structurally closed
  by `deferred-follow-ups.md` + the index closure claim.
