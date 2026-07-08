# L12 — MDL misc LOWs from the second review (fix-in-phase batch)

- **Status**: DONE — all 8 items resolved:
  1. `Coverage.insert/3` gained the same `rescue ArgumentError -> :ok` every
     other ETS accessor in the module already had. 1 repro test
     (`coverage_test.exs`), confirmed via stash to raise on unfixed code.
  2. `do_record/5`'s dedupe match now compares `&1.normalised == normalised` in
     addition to `&1.fingerprint == fingerprint` — the `Entry` already carried
     the full canonical term, just wasn't using it. 1 repro test
     (`subsumption_test.exs`) hand-crafts a same-fingerprint,
     different-`normalised` entry (a real `:erlang.phash2/1` collision is
     infeasible to search for in a fast test) as the only ledger entry, so
     traversal order can't mask the bug; confirmed via stash.
  3. `Capability.collect/2`/`simple_expression` — already fixed;
     `capability_test.exs` already has comprehensive retained coverage
     (evaluable vs. `:unknown` custom expressions). No further action.
  4. Supervisor `resources:` filtering — already fixed (`supervisor.ex:62,68`).
     New `supervisor_test.exs`: a plain non-MDL resource mixed into an explicit
     `resources:` list is filtered out before reaching `Info.orchestrator/1`,
     not crashed on; confirmed passing (validates the "fixed" label, per the
     task's own instruction for already-fixed items).
  5. Stale-check resurrection (missing remote row) — already fixed (`flush.ex`'s
     `{:ok, nil}` branch). 1 retained regression test (`local_outbox_test.exs`):
     a peer-deleted remote row's `:update` flush parks as `:conflict`, never
     resurrects it.
  6. **Explicit decision recorded**: `:upsert` intentionally bypasses
     stale-check even with `conflict_detection: {:stale_check, _}` — an upsert's
     local write never reads a prior value (no before-image exists to compare
     against; `write.ex`'s `base_image/3` correctly returns `nil` for
     `:upsert`), and treating "target already has a row" as a conflict would be
     actively wrong (that's upsert's ordinary create-if-absent-else-update case,
     not a divergence). Documented in detail at `flush.ex`'s `check_stale/2`.
     Callers needing conflict-safe semantics should use `:update` instead. 1
     retained regression test pins the documented behavior: an upsert onto a
     diverged remote row LWW-overwrites without parking.
  7. `:synced` entries are now pruned every sweep tick
     (`Sweeper.prune_synced/1`), past a configurable
     `outbox_synced_retention_ms` (default 7 days). 2 tests: an entry past the
     window is destroyed (confirmed via stash to survive on unfixed code — no
     pruning existed at all); an entry within the window survives.
  8. SQLite rowid-reuse / stale Oban uniqueness — already fixed (`write_ref` in
     job args + generated fresh per write). 1 retained regression test: discard
     an entry (freeing its row), create a new one, confirm distinct `write_ref`s
     and a successful (non-swallowed) flush.

  `INTEGRATION=1 mix test` green (333, up from 326).

- **Severity**: Low (batch)
- **Repo**: MDL (ash_multi_datalayer)
- **Source**:
  [second-review LOW findings](../../reviews/20260706-second-review-findings.md)
  not otherwise tasked; added per
  [task-coverage review F13](../../reviews/20260707-second-review-fixes-task-coverage-review.md)
- **Plan ref**: LOW disposition "Fix in the phases above" items 1–3 (phases
  A3/A5/A7)

## Defects

1. **`Coverage.insert/3` has no `ArgumentError` rescue** (the `:ets.insert` call
   at `coverage.ex:58`; `def insert(resource, tenant, entry)` at `:56`) — the
   one ETS accessor without it; a TableOwner restart mid-record crashes an
   already-succeeded read. (Plan A3 item 7. It's `insert/3` at `:56`,
   `:ets.insert` at `:58` — verified against source in loop-3.)
2. **`dedupe_key` is a bare `phash2`** (the `:erlang.phash2` call at
   `coverage.ex:582`) with no disjunct comparison — a collision (~30% birthday
   estimate at a full 10k-entry partition) widens an unrelated entry's
   `loaded_fields` (matched by fingerprint alone in `do_record/5` at
   `coverage.ex:371`), serving never-backfilled fields as nil. Store/compare the
   canonical term. (Plan A3 item 7. Loop-1 review: line 582, not 583.)
3. ~~**`Capability.collect/2` skips `simple_expression`**~~ — **FIXED in the
   uncommitted working tree** (pass-2 review verified: `capability.ex:38,56`
   handle `simple_expression`). Remaining work: retain a regression test.
4. ~~**Supervisor explicit `resources:` list isn't filtered by
   `multi_datalayer?`**~~ — **FIXED in the uncommitted working tree** (pass-2
   review verified: `supervisor.ex:62,68` both filter). Remaining work: retain a
   regression test.
5. ~~**Stale-check treats a missing remote row as "no conflict"**~~ — **FIXED in
   the uncommitted working tree** (pass-2 review verified: `flush.ex:199-203`
   returns `{:conflict, nil}` for `op == :update and not is_nil(base_image)`).
   Remaining work: retain the resurrection-scenario regression test.
6. **Stale-check bypass for `:upsert` ops** — the stale-check guard only runs
   for `:update`/`:destroy` (`flush.ex:188-193`); the upsert path supplies no
   before-image/stale-check input (`write.ex:305-308`), so an upsert landing on
   a diverged remote row silently LWW-overwrites even with stale-check on
   (loop-1 review corrected the refs from `flush.ex:175`/`write.ex:286`).
   **Explicit decision required** (spec review; plan A5 item 2 says "document
   semantics OR add a guard if unsound"): either document _why_ `:upsert` LWW is
   intentionally safe for the supported target modes, or add a guard plus a
   focused regression proving a diverged remote row is not silently overwritten.
   A bare "doc note" that doesn't make this call does not close the item.
7. **`:synced` entries are never pruned** — unbounded outbox growth; `status/1`
   scans all of a record's entries per poll. Small pruning path or documented
   retention follow-up. (Plan A4 item 5.)
8. ~~**SQLite rowid reuse after discarding the max-seq entry** inherits stale
   Oban uniqueness/backoff for a distinct new entry~~ — **FIXED in the
   uncommitted working tree** (verified 2026-07-07: `enqueue.ex:31` includes
   `"write_ref" => entry.write_ref` in the job args; `write.ex:217` generates it
   per write). Remaining work: retain the plan A4 verify-3 regression test (a
   discarded max-seq entry does not poison a later entry). (Added per pass-2
   coverage review F5 — previously had no owner.)

## Done when

- [ ] Open items (1, 2, 6, 7) fixed with a focused test, or explicitly moved to
      [deferred-follow-ups.md](deferred-follow-ups.md) with a reason
- [ ] Fixed-in-tree items (3, 4, 5, 8) each get a retained regression test —
      write the repro anyway; if it unexpectedly FAILS on current code, the
      "fixed" label was wrong: reopen the item
- [ ] Item 5's resurrection regression: peer-deleted row, `:update` flush with
      base_image → conflict, not resurrect
- [ ] Item 6's decision recorded: either the LWW-is-safe rationale (with which
      target modes) OR a guard + a diverged-remote-not-overwritten regression
- [ ] `INTEGRATION=1 mix test` green in MDL
