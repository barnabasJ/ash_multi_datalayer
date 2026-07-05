# Review: orchestrator-extraction-and-local-outbox-plan.md

**Date**: 2026-07-05
**Subject**: `docs/plans/orchestrator-extraction-and-local-outbox-plan.md`
**Reviewer pass**: 1 (adversarial, evidence-checked against the working tree at
`6b5ab7c` + uncommitted changes)
**Method**: every factual claim about the current code shape was checked against
the repo; every cross-reference to the three ADRs/RFCs and the fix plan was
read in full.

## Verdict

A well-sequenced, rigorously-gated plan whose architecture is sound and whose
risk ordering (fix-first → pure-refactor → spike → build) is correct. The
blocking issues are **not** in the design — they are in three factual
inaccuracies about the current state and one unmet prerequisite gate that the
plan presents as settled. The design-level findings below are real but
addressable; none of them overturn the approach.

## Verified accurate (spot-checks passed)

- `WriteDispatch` exists and is the write pipeline the plan moves
  (`lib/ash_multi_datalayer/write_dispatch.ex`, 160 lines — the moduledoc
  already reflects the C4 eviction agreement).
- The supporting-mechanism list (`Backfill`, `Coverage.*`, `ValueMerge`,
  `Delegate`, `SqlPassthrough`, `Capability`, `KillSwitch`, `Telemetry`,
  `Migration`) all exist as claimed and are correctly identified as
  strategy-independent.
- The ledger is raw ETS in `coverage.ex` + `coverage/table_owner.ex`, keyed
  `{tenant, entry_id}` with LRU via `loaded_at` — accurate.
- All ProvenCoverage-specific schema keys the plan moves into orchestrator opts
  exist in `Info` (`ledger_max_entries`, `divergence_sampler`,
  `local_evaluation?`/`_overrides`, `fold_aggregates?`/`_overrides`,
  `sql_join_aggregates?`/`_overrides`) at `info.ex:59-97`.
- The positional `read_order`/`write_order` authority leakage the behaviour ADR
  cites as a driver is real and pervasive: `List.last(...)` at
  `data_layer.ex:307,375,508` and `hd(...)` at `:331,342,353,511` — 7 sites.
  This both justifies the extraction and makes the Phase-1 funneling note
  load-bearing, not cosmetic.
- `read_from`/`write_through` context keys are absent from `lib/` — consistent
  with the plan's explicit deferral to Phase 4.
- `../ash_remote_cache` is ~483 lines (plan says ~480) and `../ash_remote`
  exists as the Phase-6 fold-in target.
- `example/{todo_client,todo_server}` exist as the Phase-7 seed.

## Blocking findings (factual / gate-state)

### B1 — "965 lines" is wrong, by a lot, at every revision checked

Executive Summary says `AshMultiDatalayer.DataLayer` is "965 lines". Actual:

- `data_layer.ex` at last commit (`6b5ab7c`): **996 lines**.
- `data_layer.ex` in the working tree: **1166 lines** (and actively growing —
  the uncommitted fix-plan C3/C4 work adds the epoch threading + reconcile
  pass).

The figure has not been 965 at any recent commit. The number is rhetorical
motivation for the extraction; it should be corrected or dropped (the
*decision tree in `run_query/2`* is the real motivation and is accurate —
`run_query/2` at `data_layer.ex:502` plus `source_read`/`remainder_read`/
`merged_read`/`run_region` at `:811-915`).

### B2 — The "~126 tests" gate figure (inherited from the behaviour ADR) is wrong

The behaviour ADR's mitigation states "all ~126 tests + property suites green"
and the plan's Phase-1 gate inherits that yardstick. Actual suite:
**80 tests + 5 properties (85 total), 63 excluded (integration)**. The
pure-refactor gate must be stated against the real number, and the
`INTEGRATION=1` suite (the 63 excluded) needs to be explicitly in-scope for the
"full suite green without modification" claim, since the fix plan's Phase 7
treats the integration suite as the acceptance harness.

### B3 — The Phase 0 gate is not just "not green" — it is in-flight and incomplete

Phase 0 says: "Land the critical-bugs fix plan first. Gate: that plan's own
acceptance gates green." The plan reads as if this is a settled prerequisite.
Actual repo state:

- **Committed**: only Phases 0–2 of the fix plan (`6b5ab7c Phase 0-2:
  regression harness + C1/C2 fixes`). So C1/C2 + the blocking-layer harness are
  in; the regression tests are in.
- **Uncommitted in the working tree**: Phases 3–7 — the C3 epoch mechanism
  (`coverage.ex` now carries the `{counter, incarnation}` epoch type and
  `epoch_key/1`), the C4 evict (`invalidation.ex:76-128` `evict_physical_row`),
  and the reconcile pass (`data_layer.ex:771-979`). These are *uncommitted
  modifications*, not landed.
- **Not implemented at all**: `forget!/3` (fix plan Phase 4.3, the public C4
  API) — `grep "def forget!" lib/` returns nothing. The fix plan's own Phase 4
  acceptance names this API; Phase 6 of the fix plan and Phase 6 of *this* plan
  both treat its existence as the retirement trigger for the downstream
  stopgap.
- The fix plan itself and all 12 of its review passes are **untracked files** —
  not even committed.

**Implication**: Phase 1 of this plan moves exactly the code that is currently
being rewritten in the working tree. Starting Phase 1 on top of an uncommitted,
incomplete fix plan is the precise "refactoring around known-broken code"
scenario the plan says it wants to avoid. The gate wording should be hardened
to: *the fix plan is committed, `forget!/3` exists, and `mix test &&
INTEGRATION=1 mix test` is green at the commit Phase 1 branches from* — and the
plan should note the current state explicitly so nobody branches prematurely.

## Design / consistency findings

### D1 — Supervisor "discovers configured orchestrators" — mechanism unspecified (real gap)

Phase 1 deliverable: "`AshMultiDatalayer.Supervisor` discovers configured
orchestrators and starts their `child_specs/1`". The current
`AshMultiDatalayer.Supervisor` (`supervisor.ex`, 28 lines) is a trivial single
`DynamicSupervisor` with **no resource discovery** — table owners start lazily
on first read/write (`TableOwner`), not via supervisor enumeration. Ash
resources are compile-time entities; there is no general runtime registry of
"which resources use which orchestrator". The plan states the deliverable but
gives no mechanism for the discovery itself (app-env registry? a compile-time
`@behaviour`-based registration macro the extension injects? scanning
`Ash.Registry`?). This is the one genuinely underspecified mechanism in
Phase 1. The lazy-start pattern could be preserved (orchestrator processes
start on first use, like today), but then the "`child_specs/1` started under
the supervisor" framing is misleading — clarify whether Phase 1 keeps lazy
start or introduces eager discovery, and if eager, specify the registry.

### D2 — The snooze path is load-bearing for a correctness property, but parked in a spike (highest technical risk)

RFC flush execution depends on `{:snooze, interval}` for offline-class errors,
and explicitly leverages that "snoozing costs zero retry budget" to deliver the
guarantee: *"being paused is a battery/UX nicety, never a correctness
requirement"* — an unpaused offline device snoozes forever and parks nothing.

Phase 2 item 5 concedes the snooze-via-ash_oban-action path is unverified:
*"confirm ash_oban exposes a snooze path from the action, else record the
fallback (rescue + snooze in a custom worker wrapper)"*. If ash_oban does **not**
expose an action-level snooze:

- the zero-budget-burn property breaks (offline devices burn the retry budget
  and park as `:transient_exhausted`), reopening the "parking while merely
  offline" class the RFC says is eliminated; **and**
- the fallback (custom worker wrapper) contradicts the sync-state ADR's "the
  library ships no queue, no drainer" framing and the RFC's "rows are the
  truth, jobs are ephemeral pointers" cleanliness — the library now *does* own
  worker plumbing.

This is the single highest technical risk in the arc and it is deferred to a
spike addendum. Recommend: resolve item 5 *before* finalising the RFC's
correctness claims (or reword the RFC's "never a correctness requirement" to
"subject to the Phase-2 snooze verification"). Do not let the spike answer
retroactively invalidate a normative RFC property.

### D3 — Phase 5 benchmark "honesty gate" can silently reduce Goal 3 to nominal

Phase 5 gate: if the ledger-as-resource probe exceeds 2× raw-ETS or 50µs p99,
"the raw-ETS fast path stays as the default implementation behind the same seam
and the resource port ships as opt-in only. Honesty gate: the plan does not
assume the benchmark passes." The honesty is admirable. The consequence is not
spelled out: if the gate fails, **Goal 3's stated outcome ("ProvenCoverage's
coverage ledger ported onto the same pattern") is achieved only nominally** —
the default ProvenCoverage still uses private ETS, so the sync-state ADR's
positive consequences #4 ("one SQLite file") and #5 ("makes
`mix ash_multi_datalayer.inspect` mostly a query") and the inspectability/
hookability rationale all fail to materialise for the default strategy. State
upfront, in Goal 3 itself, what "ported" means if the fast path stays raw ETS,
so the success criterion isn't quietly redefined at review time.

### D4 — "Pure refactor" gate vs. forward-compat funneling: a mild tension

Phase 1 is a pure-refactor gate ("full suite green without modification", "no
functional change rides along") and also the phase that funnels the 7 scattered
positional boundary lookups (B1's `List.last`/`hd` sites) "through one internal
function per direction". Funneling can be behaviour-preserving, but it is a
*structural reorganization* of ProvenCoverage internals, not just a move. The
risk: a mis-funneled boundary read (e.g. a fallback that used to hit
`List.last(read_layers)` now hitting the funnel's "source" port) is exactly the
kind of off-by-one-layer bug the existing test suite may not catch if it does
not exhaustively exercise multi-layer boundary reads. The plan is honest that
this is "funneling only; no port abstraction", but the gate's `git diff --stat
on test/` constraint does not actually *force* the funneling to be
behaviour-identical — it forces the tests to be unchanged, which is weaker.
Recommend: add an explicit assertion in the Phase-1 gate that the funnel
functions reproduce today's exact positional choices for every existing call
site (a one-time mapping table in the commit message), so the pure-refactor
claim is auditable rather than aspirational.

### D5 — `read_from:` ADR-vs-plan placement ambiguity

The behaviour ADR lists `read_from:` under "What stays in the shell"
(`adr:149-155`) as if it were part of the Phase-1 shell. The plan correctly
defers it to Phase 4 as new behaviour ("nothing new may ride the pure-refactor
gate"). Not a contradiction (ADR = where it *lives architecturally*; plan =
*when it ships*), but the ADR's "What stays in the shell" section should
distinguish *existing shell mechanics that Phase 1 carries* from *future shell
mechanics landing in Phase 4*, so a reader doesn't expect `read_from:` after
Phase 1.

### D6 — Phase 1 "each strategy's access to the far side" can only cover one strategy

Phase 1 says it funnels "each strategy's access to the far side of its
boundary (ProvenCoverage's source reads/writes, LocalOutbox's target flushes)".
LocalOutbox does not exist until Phase 4, so at Phase-1 exit only
ProvenCoverage's boundary is funneled. The stacked-orchestrators RFC's "cheap
forward-compat" therefore covers half the seam at Phase 1; LocalOutbox's target
funneling is necessarily a Phase-4 act. Make this explicit so the
forward-compat claim isn't over-read as "both strategies stacking-ready after
Phase 1".

### D7 — Phase 6 namespace is undecided in another repo; Phase 7 wiring is contingent on it

Phase 6: "namespace settled in ash_remote review; working shape:
`AshRemote.MultiDatalayer.ChangeNotifier` + `.LifecycleGuard`" and "whatever
the repo eventually becomes stays unnamed for now." Phase 7 wires "the ash_remote
utilities (Phase 6)" into every cached/local resource. If ash_remote's review
lands a different shape/name, Phase 7's wiring diff changes. The plan should
note Phase 7's utility-wiring sections are contingent on the Phase-6 namespace
decision (an external dependency), so the coupling is visible.

### D8 — Phase 3 extension attribute types are pending the Phase-2 spike

Open question 3 (payload/base_image encoding: embedded resource vs dumped-map
vs `:term`) is on the Phase-2 critical path but the Phase-3 deliverable list
presents the `OutboxEntry` extension's injected attributes (`payload`,
`base_image`, `remote_snapshot`) as if their types were settled. If the spike
answer is "embedded resource", the extension's attribute typing, the
generator's migration codegen, and the `Ash.load`-free rebuild path all differ
materially from a `:term`/`:map` answer. Mark the Phase-3 attribute list's
encoding-sensitive entries as "per Phase-2 item 9".

## Strengths worth preserving

- **Gating discipline**: every phase has an explicit, checkable gate; open
  questions are owned and assigned to a phase; the "no new behaviour may ride
  the pure-refactor gate" rule (read_from explicitly pushed to Phase 4) is
  observed even where it would have been convenient to fold it in.
- **Risk ordering**: fix-first (Phase 0) → spike-before-build (Phase 2) →
  pure-refactor (Phase 1) → second strategy (Phase 4) is the correct sequence
  to de-risk third-party assumptions before committing the architecture to them.
- **Offline/hex-cache discipline**: dep versions pinned and *verified present*
  in `~/.hex/packages/hexpm`; the `--no-assets` constraint on `phx.new` and
  oban_web's self-contained assets are the kind of offline gotcha that usually
  surfaces mid-build. Good upfront research.
- **Durability matrix** (RFC): the local-layer × outbox-layer table is sound,
  and the co-commit invariant ("the local write + enqueue commit in one
  transaction") is the right construction-over-documentation move.
- **Forward-compat without premature abstraction**: the funneling note is a
  cheap-now/expensive-later call that leaves the exploratory stacked-
  orchestrators RFC a real seam without building the port. Good restraint.
- **Honesty gates**: Phase 5's "the plan does not assume the benchmark passes"
  is the right epistemic posture (even if D3 asks its consequence be spelled out).
- **C4 fold-back**: correctly identifies `forget!/3` (fix plan Phase 4.3) as the
  retirement trigger for the downstream stopgap — the cross-plan dependency is
  tracked, even though the API is not yet implemented (B3).

## Recommendations (ordered)

1. **(B3, blocking)** Rewrite the Phase-0 gate to require the fix plan
   *committed* (not just green in the working tree) and `forget!/3`
   *implemented*, and state the current in-flight status explicitly. Do not
   branch Phase 1 from an uncommitted, incomplete fix.
2. **(B1, B2)** Correct "965 lines" to the actual figure (or drop it) and
   restate the pure-refactor gate against the real suite count, explicitly
   including the `INTEGRATION=1` suite.
3. **(D2)** Resolve the ash_oban action-snooze question before treating the
   RFC's "never a correctness requirement" offline property as normative.
4. **(D1)** Specify the supervisor discovery mechanism, or reframe Phase 1 to
   preserve the existing lazy-start pattern (and drop the
   "discovers + starts `child_specs/1`" wording).
5. **(D3)** State in Goal 3 what success means if the Phase-5 benchmark fails
   and the default stays raw ETS.
6. **(D4)** Make the funneling mapping auditable in the Phase-1 commit (table
   of old positional site → new funnel function).
7. **(D5–D8)** Editorial: ADR shell-list clarification; Phase-1 funneling
   scope ("ProvenCoverage only at Phase 1"); Phase-7 contingency on Phase-6
   namespace; Phase-3 attribute-type pending spike.

## Items explicitly *not* flagged

- The strategy naming convention (mechanism, not category) is correct and the
  precedent is well-argued in the ADR.
- The decision to drop the bespoke drainer/store/handler in favour of Oban +
  ash_oban + app-owned resources is the right call and well-justified against
  its alternatives.
- The non-goals (no merge/CRDT, no partial hydration in LocalOutbox, no Oban
  Pro, no multi-node, no stacked orchestrators in-arc) are correctly scoped
  out.
- The kill-switch-vs-pause distinction ("opposites, not variants") is clear
  and correct.

---

**Last Updated**: 2026-07-05
