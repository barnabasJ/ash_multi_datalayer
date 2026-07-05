# Review (pass 3): Orchestrator Extraction + LocalOutbox Plan

**Metadata:**

- Type: review
- Status: complete
- Created: 2026-07-05
- Subject:
  [docs/plans/orchestrator-extraction-and-local-outbox-plan.md](../plans/orchestrator-extraction-and-local-outbox-plan.md)
  (v2 — the post-pass-1 edit incorporating F1–F11)
- Relationship to prior reviews:
  - [pass 1](./20260705-orchestrator-extraction-and-local-outbox-plan-review.md)
    (F1–F11, all incorporated into v2)
  - [pass 2](./20260705-orchestrator-extraction-and-local-outbox-plan-review-pass2.md)
    (F1–F7, **partially** incorporated — see R5–R9 below)
- Method: re-verified every claim that touched the code or repo state against
  the working tree at `b290e0d`; confirmed the Phase 4a capability-derivation
  basis against `data_layer.ex:255-339`.

## Verdict

v2 is a materially better plan. The snooze risk is closed, the co-commit
predicate is corrected, `read_from:` is split out of Phase 4's clean-seam diff,
the two-instance mechanism and `oban_instance` are committed scope, and the
ash_remote_cache module inventory is complete. **The blocking items are now
two: pass-2's critical DSL-key/gate conflict (R5) is unaddressed, and the
facts section is stale in the opposite direction from pass 1 (the fix plan is
now fully landed, so Phase 0 is satisfiable but the plan reads as if it
isn't).** Several pass-2 warnings also remain open.

## Resolved since v1 / pass 1 (verified, not re-raised)

- **Snooze (pass-1 F11, my earlier D2): closed.** v2 facts record the verified
  `AshOban.Errors.SnoozeJob` → `{:snooze, seconds}` path; Phase 2 item 5
  correctly shrinks to a single confirmation test. The RFC's zero-budget-burn
  property now rests on a real path.
- **Co-commit predicate (pass-1 F1): closed.** Phase 4 write path and Phase 2
  item 8 now gate on *same Ecto repo* + raw `Repo.transaction/1`, explicitly
  NOT `can?(:transact)` (which ash_sqlite hardcodes false). Verified grounded:
  the current `can?(:transact)` is the write-order intersection
  (`data_layer.ex:257,313`) while `transaction/4` delegates to authority alone
  (`:330`) — so the Ash capability and the actual transaction path already
  disagree, exactly as Phase 4a notes.
- **Clean-seam split (pass-1 F2 / pass-2 F2): closed.** New Phase 4a carries
  `read_from:`/`write_through:` and the capability rework; Phase 4's gate now
  includes an explicit "Seam gate" (plan:405-407) checkable by inspection.
- **Two-instance e2e + `oban_instance` (pass-1 F3): closed.** `oban_instance`
  is committed Phase 3 scope (plan:323-327); the parameterized-supervision-tree
  mechanism is stated (plan:575-582).
- **ash_remote_cache inventory (pass-1 F4/F10): closed.** All five `lib/`
  modules have a named destination (plan:517-534); the retirement breadcrumb and
  path-dep note are present (plan:535-544).
- **Behaviour completeness (pass-1 F6): closed.** Phase 1 now lists all 13
  callbacks, with the inbound pair *defined* in Phase 1 and *implemented* in
  Phase 4 as a stated deferral (plan:204-211).
- **`seq` on SQLite (pass-1 F7): closed.** New Phase 2 item 9 (plan:283-286).
- **Line-count / blocking-layer-tense facts (pass-1 F8/F9): closed.** The "965
  lines" figure is gone; blocking_layer described as existing (plan:117-118).

## New findings against v2

### R1 (major) — facts section is stale: the Phase 0 gate is now *satisfied*, but the plan reads as if it isn't

The facts section records (plan:115-118): *"fix-plan Phases 0–2 ... committed
at `6b5ab7c`; C3/C4 in the working tree; M1 pending."* That was accurate at
pass-1 time. It is no longer accurate. Current repo state:

```
b290e0d Phase 7: update technical docs; mark C1-C4/M1 fixed in review docs
2aca728 Phase 7: fix Ash.Resource.record()/0 dialyzer regression in touched files
8213163 Phase 6: harden the suite around the fixed class
e1fa3cc Phase 5: M1 - touch/3 must not resurrect a dropped ledger entry
ba7e3d0 Phase 3-4: C3 invalidation epoch + C4 evict/reconcile/forget! (fix plan)
```

The fix plan is **fully landed** through Phase 7; `forget!/3` exists at
`lib/ash_multi_datalayer.ex:53`; the suite grew from 87 to 97 tests (Phase 6
hardening). The facts header hedges with "at plan-review time", so it is not
*wrong* as a snapshot, but a reader will act on it as current. **Recommend:**
add a one-line "current status" note that the Phase 0 gate is now satisfied at
`b290e0d`, so Phase 1 can branch. (My earlier B3 blocking finding is resolved
by the landing; this R1 is the documentation trailing the reality.)

### R2 (major) — Phase 4a's "per-query serving degradation" is a hot-path mechanism with no cost note

Phase 4a (plan:445-451) introduces a runtime check: *"before serving a covered
read, the router checks the cache layer can execute the query's actual shape
(extend the existing `AshMultiDatalayer.Capability` pattern) and falls through
on a gap."* This runs on **every covered read** (the hit path), not the miss
path. The existing `Capability` module probes expression evaluability once per
read; extending it to cover the query's full shape (filters, sorts, distinct,
aggregate-filter) on every cache hit is a non-trivial per-hit cost, and the
covered-hit path is the exact place ProvenCoverage's value proposition lives
(sub-µs probe, per the Phase 5 benchmark budget).

The plan gives Phase 5 (the ledger probe) a benchmark gate and a < 50µs p99
budget, but gives this new per-hit serving check **no cost note and no gate**.
If the per-query degradation check is expensive, it erodes the hit-rate win it
exists to enable. **Recommend:** either (a) state that the check is
filter/sort/etc.-structural and O(query shape), not O(data), and so bounded;
or (b) add a budget assertion to the Phase 4a gate (e.g., "covered-read probe
overhead within X of today's `covers?` probe"). Do not leave the hot-path cost
implicit.

### R3 (major) — lock-branch gate is "resurrected OR removed" — the intended outcome is ambiguous

Phase 4a (plan:437) makes ProvenCoverage's `{:lock,_}` authority-only, framing
this as *"fixes N10's dead lock-routing branch"*. The gate (plan:462) then
says: *"the lock-routing branch is reachable (N10 dead code resurrected **or**
removed)"*. "Resurrected or removed" describes two opposite outcomes. Today
there is no explicit `{:lock, _}` clause in `can?` (confirmed: it falls through
to the read intersection at `data_layer.ex:317-318`), and the lock second-head
lives in `SqlPassthrough` (`:449`). If authority-only `{:lock,_}` now returns
`true`, lock requests may route to a path that was previously dead — is that
intended behaviour (ProvenCoverage *can* honor a lock when the authority
supports it) or is the branch meant to stay dead and just stop being
mis-decided? The plan must pick one: resurrect (and test the newly-live lock
path) or remove (and assert `{:lock,_}` is `false`). As written, an implementer
can satisfy "resurrected or removed" with either, and they are not equivalent.

### R4 (moderate) — Goal 2b is net-new scope; the arc should acknowledge the enlargement

Goal 2b ("honest capabilities") and the entirety of Phase 4a did not exist in
v1 of this arc. It is good work — the `can?` inconsistencies it targets are
real (R2's grounding above confirms `:transact` vs `transaction/4` already
disagree in tree) — but it is a scope *addition*, not a refinement of the
extraction/LocalOutbox story the plan's title advertises. Phase 4a's own gate
concedes *"behavioural deltas are expected here"* (plan:464-465), which is the
opposite posture to Phase 1's pure-refactor gate. **Recommend:** add a sentence
to Goal 2b / the Executive Summary acknowledging that the capability rework is
a v2 scope addition motivated by the aggregate-filter crash and N10, so the
arc's growth is visible and a reader doesn't infer it was always in scope. (If
the intent is to defer it post-arc, say so — it currently sits on the Phase 7
critical path via "Phase 7 needs 3+4+4a+6".)

## Pass-2 findings not yet incorporated

These are the highest-value items in this pass: pass 2 raised them against v1,
v2's edit incorporated pass 1 but not pass 2, and they remain live.

### R5 (critical — pass-2 F1 restated) — Phase 1's pure-refactor gate contradicts moving the DSL keys

Phase 1 moves ProvenCoverage-specific keys (`ledger_max_entries`,
`divergence_sampler`, `local_evaluation?`/`_overrides`,
`fold_aggregates?`/`_overrides`, `sql_join_aggregates?`/`_overrides`) out of
the `multi_data_layer` section into orchestrator opts (plan:214-218), **and**
the gate requires `git diff --stat on test/ is empty except for any new
orchestrator-behaviour unit tests` (plan:245-246). These are mutually
exclusive as written: the existing resources and DSL tests declare those keys
at the section level (`data_layer.ex:94-196` carries the section schema;
`test/ash_multi_datalayer/data_layer_dsl_test.exs` and `verifiers_test.exs`
exercise them), so moving the keys breaks the declarations unless section-level
aliases are retained. The plan's only mitigation — "Info getters re-routed
through `orchestrator/1` so call sites need not all change at once"
(plan:217-218) — covers *getter call sites*, not the *DSL declarations
themselves*. v2 must pick one explicitly:

- keep top-level section aliases (forwarding) for ProvenCoverage during Phase 1
  so existing declarations compile unchanged; or
- relax the Phase 1 gate to allow intentional edits to test-support resource
  declarations and the DSL tests as part of the schema move.

Without the decision, an implementer can satisfy the gate or the move, not
both. This is the one true blocker in this pass.

### R6 (warning — pass-2 F3 restated; my earlier D1) — supervisor discovery mechanism still unspecified

Phase 1 (plan:239-241) still says the supervisor *"discovers configured
orchestrators and starts their `child_specs/1`"* with no discovery input. The
current supervisor (`supervisor.ex`, 28 lines) ignores opts and starts a single
`DynamicSupervisor`; table owners start lazily on first read/write. This
matters more now that LocalOutbox hydration sits under `child_specs/1`
(plan:366): a lazy first-read start cannot guarantee `:if_empty`/`:on_start`
hydration *before* the resource is served. Pick: (a) `domains:`/`resources:`
supervisor opts emitted by the Phase 3 installer, giving eager discovery; or
(b) keep ProvenCoverage lazy and make LocalOutbox require configured resource
discovery. State which.

### R7 (warning — pass-2 F4) — non-goal "never by merge" contradicts Phase 7's merge UI

Non-Goals (plan:157-160): concurrent edits *"resolve by LWW-or-park, never by
merge"*. Phase 7 (plan:641-644): a **Merge** button doing field-level merge →
`rebase/2`. The RFC itself calls `rebase/2` *"the application's merge hook"*
(rfc:479-481). The intended boundary is clearly "the *library* never
automatically merges", but the non-goal as worded forbids the very thing
Phase 7 ships. Reword to reject library/automatic/CRDT merge while allowing
application-mediated merge through `rebase/2`.

### R8 (warning — pass-2 F5) — Phase 4 co-commit/crash gate still conflates two windows

Phase 4 gate (plan:396): *"co-commit atomicity (kill between steps — sweeper
recovery)"* as one item. The RFC separates these: (1) local write + enqueue
co-commit *before return* (rfc:177-183); (2) post-commit `run_trigger` kick
with cron-sweeper recovery if the kick is lost (rfc:184-187). Keeping them
fused risks testing only the sweeper path and never asserting the actual
co-commit invariant (a crash cannot leave a committed local row without its
outbox entry). Split into two named tests. (Phase 2 item 8 now exercises the
co-commit primitive, which is the right place to pin the atomicity half; the
Phase 4 gate should cross-reference it rather than re-fuse.)

### R9 (warning — pass-2 F6) — Phase 3 generator gate still lacks idempotency and runtime-wiring checks

Phase 3 gate (plan:329-333) checks compile + verifier rejection + unit tests.
The sync-state ADR additionally requires the generators to be
additive/idempotent and to compose `ash_oban.install` + ash_sqlite repo/config
+ migrations + queue wiring (adr:161-170). Compilation will not catch a
duplicated supervisor entry, a second run duplicating formatter/config, a
mismatch between the generated Oban queue and the generated ash_oban trigger,
or a repo that boots but cannot run a migrated Oban Lite. Add gate items:
re-run idempotency (no duplicate config/resources/migrations); boot the
generated repo against a temp SQLite file with Oban Lite migrated; assert the
generated queue config matches the trigger.

## Carried forward (still open from my earlier review)

- **Phase 5 escape-hatch consequence (my D3):** Phase 5 gate (plan:485-489)
  still ends *"the raw-ETS fast path stays as the default... the resource port
  ships as opt-in only"* without stating what that means for Goal 3's stated
  outcome ("ProvenCoverage's coverage ledger ported onto the same pattern"). If
  the gate fails, "ported" is achieved only nominally — the default keeps
  private ETS, so the inspectability/hookability/`inspect`-as-a-query
  rationale fails to materialise for the default strategy. State in Goal 3 what
  success means if the fast path stays raw ETS.
- **Funneling auditability (my D4):** Phase 1's funneling of the 7 positional
  boundary lookups (`List.last`/`hd` at `data_layer.ex:307,331-353,375,508,511`)
  into one internal function per direction is a structural reorganization, and
  the `git diff --stat` test gate does not force it to be behaviour-identical.
  With Phase 4a now carrying the deliberate behaviour changes elsewhere, the
  Phase 1 funneling is the *only* non-move structural act left — making the
  auditability ask more pressing, not less: include an old-site → new-funnel
  mapping table in the Phase 1 commit so the pure-refactor claim is auditable.
- **Phase 1 funneling scope wording (my D6):** plan:232-234 still says "each
  strategy's access to the far side of its boundary (ProvenCoverage's source
  reads/writes, LocalOutbox's target flushes)". LocalOutbox does not exist
  until Phase 4, so only ProvenCoverage's boundary can be funneled at Phase 1
  exit. Say so, so the stacked-orchestrators "cheap forward-compat" isn't
  over-read as "both strategies stacking-ready after Phase 1".

## Minor / editorial

- **R10 (minor)** — Phase 2 item 9 `seq` options (plan:283-286): the
  `max(seq)+1`-inside-the-enqueue-transaction option is "safe under SQLite's
  single-writer" but leans entirely on item 8's `Repo.transaction` being truly
  serializing. If item 8 reveals any non-serializing behaviour (e.g., sandbox
  isolation in tests), `max(seq)+1` reintroduces a race on the write path. The
  integer-PK/rowid option is unambiguously safe. State a preference order
  (integer PK preferred; `max(seq)+1` only if the uuid-PK is load-bearing and
  item 8 confirms strict serialization).
- **R11 (minor)** — OQ3 (plan:693) now correctly routes payload encoding to
  "Phase 2 item 10 decides", but the RFC still labels it a "Phase-3 spike
  deliverable" (rfc:583-587). The plan is right; the RFC label is stale. (This
  is pass-1 F9 / pass-2 F7, plan-side fixed, RFC-side outstanding — flag for
  the Phase 8 docs closure or an RFC touch-up.)

## Strengths preserved / new in v2

- The Phase 4a capability-derivation basis is **well-grounded in the current
  code**: I confirmed `:transact` is answered by the write intersection
  (`:257,313`) while `transaction/4` delegates to authority alone (`:330`),
  `:select` is already authority-only (`:306-311`), and `:multitenancy` is the
  all-layers intersection (`:297-299`) — every claim Phase 4a makes about
  today's `can?` matches the tree. The "honest capabilities" diagnosis is
  correct even if the scope enlargement (R4) and hot-path cost (R2) need
  addressing.
- The Phase 4a split is the right structural call: it isolates the deliberate
  behaviour changes from both Phase 1's pure-refactor gate and Phase 4's
  clean-seam gate, so each gate actually proves what it claims.
- The "hardcoded `false` only as documented bypass-guards" rule (plan:431-435,
  384-386) — with the ash_sqlite-answers-true-to-`update_query` rationale
  (plan:104-109) — correctly identifies *why* blind layer delegation is unsafe
  and keeps those guards load-bearing across the rework.
- Sequencing rule (plan:177-182) correctly places Phase 4a after Phase 4 and
  notes Phase 7 needs it; the phase graph remains coherent.

## Recommended edits, ordered

1. **(R5, blocker)** Add Phase 1's DSL-key decision: section aliases retained
   OR gate relaxed. One sentence; unblocks the whole phase.
2. **(R1)** Update facts-section status to reflect the fix plan fully landed at
   `b290e0d`; note Phase 0 is satisfiable.
3. **(R2)** Add a cost note / budget to the Phase 4a per-query serving
   degradation check (it is on the covered-read hot path).
4. **(R3)** Disambiguate the lock-branch outcome (resurrect vs remove) in the
   Phase 4a gate.
5. **(R6/R7/R8/R9)** Incorporate the four open pass-2 warnings (supervisor
   discovery mechanism; merge non-goal wording; split co-commit/crash gate;
   generator idempotency + runtime-wiring gate).
6. **(R4)** Acknowledge Goal 2b / Phase 4a as a v2 scope addition.
7. **(D3/D4/D6 carry-forward)** State Goal 3's success criterion if the Phase 5
   benchmark fails; require the funneling mapping table; correct the
   funneling-scope wording.
8. **(R10/R11, editorial)** `seq` preference order; RFC OQ3 label touch-up.

## Items explicitly *not* flagged

- The snooze, co-commit, clean-seam, two-instance, module-inventory, and
  behaviour-completeness resolutions are genuine and verified.
- The capability-derivation *diagnosis* (Phase 4a's basis) is correct against
  the current code; only its scope framing (R4) and hot-path cost (R2) and one
  ambiguous gate (R3) are at issue, not the underlying analysis.
- Non-goals (no CRDT/library-merge, no partial hydration, no Oban Pro, no
  multi-node, no stacked orchestrators in-arc) remain correctly scoped once R7
  rewords the merge line.

---

**Last Updated**: 2026-07-05
