# Follow-up Review: Orchestrator Extraction + LocalOutbox Plan

**Metadata:**

- Type: review
- Status: complete
- Created: 2026-07-05
- Subject:
  [docs/plans/orchestrator-extraction-and-local-outbox-plan.md](../plans/orchestrator-extraction-and-local-outbox-plan.md)
- Relationship to prior review:
  [20260705-orchestrator-extraction-and-local-outbox-plan-review.md](./20260705-orchestrator-extraction-and-local-outbox-plan-review.md)
  already covers dependency/package checks and several major plan issues. This
  pass focuses on additional acceptance-gate, sequencing, and implementation
  feasibility findings against the current working tree.

## Findings

### F1 (critical) - Phase 1's pure-refactor gate conflicts with moving existing DSL keys

Phase 1 moves ProvenCoverage-specific DSL keys from the `multi_data_layer`
section into `orchestrator` opts (`docs/plans/orchestrator-extraction-and-local-outbox-plan.md:173-179`),
but the Phase 1 gate requires the full suite to stay green with no test changes
except new orchestrator-behaviour unit tests (`:204-207`). That is not achievable
as written: current resources and tests still use top-level keys such as
`ledger_max_entries`, `divergence_sampler`, and
`sql_join_aggregate_overrides` (`lib/ash_multi_datalayer/data_layer.ex:94-196`,
`test/ash_multi_datalayer/data_layer_dsl_test.exs:20-28`,
`test/ash_multi_datalayer/verifiers_test.exs:283-319`).

The plan needs to pick one explicit path:

- Keep top-level aliases/default forwarding for ProvenCoverage during Phase 1,
  so existing tests and resource declarations remain valid.
- Or relax the pure-refactor gate and allow updating test/support resource DSL
  declarations and DSL tests as part of the intentional schema change.

Without that decision, implementers can satisfy either the schema move or the
unchanged-test gate, but not both.

### F2 (critical) - Phase 4 includes a shell data-path change while using "no shell data-path changes" as the proof

Phase 4's objective says LocalOutbox must land without modifying the shell data
path (`docs/plans/orchestrator-extraction-and-local-outbox-plan.md:285-289`),
but Phase 4 also introduces shell-level `read_from:` forced reads
(`:322-329`). The ADR confirms `read_from:` is shell-owned and short-circuits
before orchestrator dispatch (`docs/design/20260705-orchestrator-behaviour-adr.md:149-155`).

This makes the Phase 4 validation criterion ambiguous: the LocalOutbox diff
cannot prove the seam is real if it also edits the shell read path. Split
`read_from:` into its own phase/commit with its own acceptance gate, or relax the
"without modifying the shell's data-path code" criterion.

### F3 (warning) - Supervisor discovery is specified as a deliverable but not as an implementable mechanism

Phase 1 says `AshMultiDatalayer.Supervisor` will discover configured
orchestrators and start their `child_specs/1`
(`docs/plans/orchestrator-extraction-and-local-outbox-plan.md:200-202`). The
current supervisor ignores opts and only starts `AshMultiDatalayer.TableSupervisor`
(`lib/ash_multi_datalayer/supervisor.ex:16-27`); coverage owners are currently
lazy per-resource processes (`lib/ash_multi_datalayer/coverage/table_owner.ex:5-8`).

That matters more once LocalOutbox hydration is placed under `child_specs/1`
(`docs/plans/orchestrator-extraction-and-local-outbox-plan.md:310`): a lazy
first-read start cannot also guarantee `:if_empty` / `:on_start` hydration
before the resource is served.

Specify the discovery input in the plan, for example `domains:` / `resources:`
supervisor opts emitted by the installer, or explicitly keep ProvenCoverage lazy
and make LocalOutbox require configured resource discovery.

### F4 (warning) - The non-goal rejects merge while Phase 7 requires a merge UI

The non-goals say concurrent edits resolve by LWW-or-park, "never by merge"
(`docs/plans/orchestrator-extraction-and-local-outbox-plan.md:124-127`). Phase 7
then requires a first-class conflict UI with field-level merge that submits a
changeset through `rebase/2` (`:476-485`). The LocalOutbox RFC also describes
`rebase/2` as the application merge hook (`docs/design/20260705-local-outbox-orchestrator-rfc.md:479-481`).

The intended boundary appears to be "the library does not automatically merge."
Reword the non-goal to reject CRDT/server/library-side merge, while allowing
application/UI-mediated merge via `rebase/2`.

### F5 (warning) - Phase 4's co-commit/crash test conflates two different windows

Phase 4's gate lists "co-commit atomicity (kill between steps - sweeper
recovery)" as one test item
(`docs/plans/orchestrator-extraction-and-local-outbox-plan.md:339-340`). The RFC
separates these invariants: local write + outbox enqueue co-commit before return
(`docs/design/20260705-local-outbox-orchestrator-rfc.md:177-183`), then
post-commit `run_trigger` kick with cron sweeper recovery if the kick is lost
(`:184-187`).

Split the gate into two tests:

- Same-repo co-commit: a crash/failure cannot leave a local row without its
  outbox entry.
- Post-commit kick recovery: committed outbox rows still drain if the process
  dies before or during `AshOban.run_trigger/3`.

Keeping them combined risks testing only the sweeper path while missing the
actual co-commit atomicity invariant.

### F6 (warning) - Phase 3 generator acceptance misses idempotency and runtime wiring checks

Phase 3's gate checks that the generator runs, generated resources compile,
verifiers reject bad setups, and injected actions have unit tests
(`docs/plans/orchestrator-extraction-and-local-outbox-plan.md:279-283`). The
sync-state ADR also requires the generators to be additive/idempotent and to
compose `ash_oban.install`, ash_sqlite repo/config, migrations, and queue wiring
(`docs/design/20260705-sync-state-as-ash-resources-adr.md:161-170`).

Add acceptance checks for:

- Re-running the installer/generator without duplicating config, formatter
  entries, supervisor children, migrations, or resources.
- Booting the generated repo against a temp SQLite database with Oban Lite
  migrated.
- Verifying the generated Oban queue/config matches the generated ash_oban
  trigger.

Compilation alone will not catch broken runtime queue wiring.

### F7 (suggestion) - Payload encoding ownership is inconsistent between plan and RFC

The plan assigns payload/base-image encoding to Phase 2 item 9
(`docs/plans/orchestrator-extraction-and-local-outbox-plan.md:242-244`) and the
open questions say Phase 2 decides it (`:531-534`). The RFC still calls the same
answer a Phase 3 spike deliverable
(`docs/design/20260705-local-outbox-orchestrator-rfc.md:583-587`).

Make the ownership consistent. Phase 2 is the better owner because the answer
changes the Phase 3 extension's attribute types and generated migrations.

## Summary

- Critical: 2
- Warnings: 4
- Suggestions: 1

---

**Last Updated**: 2026-07-05
