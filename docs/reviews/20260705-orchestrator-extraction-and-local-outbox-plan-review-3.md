# Review 3: Orchestrator Extraction + LocalOutbox Plan (revision 3)

**Metadata:**

- Type: review
- Status: complete
- Created: 2026-07-05
- Subject:
  [docs/plans/orchestrator-extraction-and-local-outbox-plan.md](../plans/orchestrator-extraction-and-local-outbox-plan.md)
  (revision claiming all findings from five review passes incorporated)
- Prior reviews in this series:
  [review 1](./20260705-orchestrator-extraction-and-local-outbox-plan-review.md)
  (F1–F11),
  [review 2](./20260705-orchestrator-extraction-and-local-outbox-plan-review-2.md)
  (R1–R7)
- Method: full re-read; incorporation check of review-2 R1–R7 (done inline);
  delegated audit of the three passes from the other review series (adversarial
  pass 1 B1–B3/D1–D8, pass 2 F1–F7, pass 3 R1–R11) against the plan text and the
  ADR/RFC; git-state verification of the new "fix plan fully landed" claim.

## Verdict

**The plan is ready to execute.** The "Reviewed (all incorporated)" metadata
claim holds on substance: all 22 findings from the other review series and all 7
from review 2 are addressed — most near-verbatim, several by fixing the
referenced design doc directly (D5 → ADR, R11 → RFC, both verified). The new
load-bearing fact — the critical-bugs fix plan fully landed at `b290e0d` with
`forget!/3` public and the C3/C4/M1 regression tests committed — verified
against git. What remains is one small mechanical gap in the two-instance story
and a handful of attribution/ bookkeeping nits. Nothing blocks Phase 1.

## Findings

### V1 (minor) — `put_dynamic_repo` is per-process and not inherited; two process classes still lack an establishment point

Phase 7's repo-selection paragraph (the review-2 R2 fix) is right in outline but
its wording implies inheritance that doesn't exist — `Repo.put_dynamic_repo/1`
writes the **calling process's** dictionary; nothing flows down a supervision
tree. Walking the process classes:

- Endpoint/LiveViews "via an instance plug/hook" — correct as stated.
- Strategy processes "via `child_specs/1` opts" — correct as stated.
- **Oban workers "via the instance's own Oban tree" — not a mechanism.** A
  worker process spawned by instance B's queue producer starts with an empty
  process dictionary. The concrete fix is cheap and worth recording: the flush
  worker's `perform/1` receives `job.conf.name` (the Oban instance it is running
  under) and establishes `put_dynamic_repo(repo_for(instance))` as its first act
  — MDL owns the flush body (Phase 3), so this lands in library code.
- **The write-path enqueue + post-commit kick run in the _caller's_ process**
  (the LiveView or test process doing the `Ash.create`), and need the target
  **Oban instance name** there, not just the repo. The instance plug/hook that
  establishes the dynamic repo should establish the instance's Oban name in the
  same process-scoped way (or the orchestrator derives it from the active
  dynamic repo via its instance config). Today the plan routes instance config
  only to strategy processes.

One edit to the Phase 7 mechanism paragraph (and a matching sentence in Phase
3's `oban_instance` deliverable) closes both. Phase 2 item 11 already exercises
the named-instance insert; extending its assertion to "from a worker running
under instance B, resolved via `job.conf.name`" would pin the tricky half.

### V2 (nit) — two attribution loosenesses around review citations

- Phase 1's gate says "(review B2: ~97 unit/property tests at `b290e0d` — not
  the ADR's stale '~126')". B2's actual count was **85** (80 tests + 5
  properties) at its commit; **~97 is pass-3 R1's post-hardening count**.
  Substance right, citation loose. Also, the ADR is no longer "stale" — it
  already says ~97 and flags ~126 as wrong itself — so the parenthetical now
  mischaracterizes a corrected doc.
- Phase 4a's "(**decision, review R3: the lock branch is resurrected**...)"
  reads as if R3 recommended resurrection; R3 was deliberately neutral ("pick
  one"), and the direction came from N10 (which the plan also cites,
  accurately). Reword to "decision (per R3's demand), direction per N10".

### V3 (nit) — count and commit-chain precision in the facts section

- The commit chain omits `2aca728` ("fix Ash.Resource.record()/0 dialyzer
  regression") between `8213163` and `b290e0d`. Inconsequential, but the facts
  section exists to be exact.
- A grep of committed test files counts **90** `test`/`property` macros outside
  `test/integration` (plus 70 in it), vs the recorded "~97".
  Generated/parameterized tests plausibly account for the difference — record
  the counting method ("`mix test` reports N") so the number is reproducible
  rather than re-litigated each review.

### V4 (housekeeping) — working tree not clean at review time

`example/todo_client/lib/todo_client/live.ex` carries an uncommitted
modification unrelated to the fix plan or this plan. Phase 0's hardened gate
("committed, green at the exact commit Phase 1 branches from") is about the
library, so this doesn't block — but commit or drop it before branching so the
Phase 1 diff starts from a clean tree.

## Incorporation verification

### Review 2 (R1–R7) — all incorporated

- **R1** (ash_oban named-instance gap): facts entry added; Phase 3 respecced
  around **MDL-owned Oban touchpoints** (insert via the generated worker +
  `Oban.insert(instance, job)`, `scheduler_cron false`, MDL sweep worker in the
  instance's cron — and the claim that pause/resume/introspection already take
  the instance as first argument is correct Oban API); new **Phase 2 item 11**
  proves the mechanism before Phase 3 builds on it. Exactly the recommended
  shape.
- **R2** (repo hook): named — dynamic repo via double-started repo module
  - per-process `put_dynamic_repo`, with MDL-internal call sites called out. See
    V1 for the two process classes still missing an establishment point.
- **R3** (facts "two components"): fixed — facts now say five modules and
  identify `CacheLayer` as the C4 stopgap.
- **R4** (Capability overstatement): fixed — now "new machinery following the
  `Capability` module's pattern", with the two-call-site reality stated, plus a
  hot-path cost bound added via pass-3 R2.
- **R5** (`{:atomic,_}` wildcard): fixed — the three explicit clauses and the
  catch-all are now stated.
- **R6** (transitional states): both notes added (Phase 1 capability-placement
  deferral; Phase 4 masked-until-4a `can?` answers).
- **R7** (multitenancy on sqlite): the verify-time rejection is in Phase 4's
  verifier list.

### Other review series (B1–B3, D1–D8, pass-2 F1–F7, pass-3 R1–R11) — all 22 verified incorporated

Audited each finding against the plan text (and the ADR/RFC where the finding
targeted those). Highlights:

- **Pass-2 F1 / pass-3 R5** (the critical DSL-key vs pure-refactor-gate
  conflict): resolved by option (a) — section-level aliases retained in Phase 1
  forwarding into ProvenCoverage opts, removal in Phase 4a with the
  declaration/test updates enumerated in that commit. Coherent and complete.
- **B3 / pass-3 R1**: Phase 0's gate hardened to committed-and-green, and the
  status genuinely satisfied — verified at `b290e0d` (HEAD), with `forget!/3` at
  `lib/ash_multi_datalayer.ex:53` and the three regression test files committed.
- **Pass-1's "7 positional sites"**: the review really does enumerate 7
  (`List.last` ×3, `hd` ×4); the plan's citation is accurate, and D4's
  commit-message mapping table + D6's ProvenCoverage-only scope note are both
  present.
- **Pass-3 R2/R3/R8/R9/R10**: cost bound (structural, O(query shape), measured
  vs `covers?`) — both recommended branches taken; lock-branch decision made
  with a test for the newly-live path; the two crash-window tests are separately
  named with the item-8 cross-reference; generator runtime-wiring gate items
  present as a superset; `seq` preference order near-verbatim.
- **D5 and R11** were fixed in the ADR and RFC respectively — verified in those
  files, not taken on faith.
- **Cross-review conflicts**: none required arbitration beyond the test-count
  baseline noise (B2's 85 vs R1's 87→97), which the plan resolved correctly by
  pinning to the latest verifiable commit.

## Suggested edits (all small)

1. **V1**: add the two missing instance-establishment points (Oban worker via
   `job.conf.name` in the flush body; caller-process kick via the instance
   plug/hook) to Phase 7's mechanism paragraph and Phase 3's `oban_instance`
   deliverable; optionally extend Phase 2 item 11's assertion accordingly.
2. **V2**: re-attribute the ~97 count to pass-3 R1; drop "the ADR's stale
   '~126'" (the ADR is corrected); reword the R3 "decision" parenthetical.
3. **V3**: add `2aca728` to the commit chain; record the test-count method.
4. **V4**: commit or discard the stray `todo_client/live.ex` change before
   branching Phase 1.

---

**Last Updated**: 2026-07-05
