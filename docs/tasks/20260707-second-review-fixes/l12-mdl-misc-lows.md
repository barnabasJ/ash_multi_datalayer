# L12 — MDL misc LOWs from the second review (fix-in-phase batch)

- **Status**: OPEN
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
