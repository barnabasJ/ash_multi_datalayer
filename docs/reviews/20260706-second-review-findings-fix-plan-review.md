# Review: the 2026-07-06 second-review-findings fix plan

**Date**: 2026-07-06 **Input**:
[the plan](../plans/20260706-second-review-findings-fix-plan.md) against
[the second-review findings](../reviews/20260706-second-review-findings.md),
verified against source in both repos. **Verdict**: strong plan — comprehensive
coverage of all 11 HIGH + 17 MED findings, sound fix directions for the ones I
traced, correct dependency ordering, and honest repro-first gates. One
cross-cutting warning: the plan's transactional guarantees (A5 #4/#7) and the
already-shipped rebase cleanup rely on `Ash.DataLayer.transaction`, which is a
**no-op on AshSqlite** (the flagship stack) — the second review flagged exactly
this as a LOW and the plan dropped it. That LOW needs disposition and the plan
must standardize on the Ecto co-commit repo transaction. One suggestion on the
attribute-tenant key derivation.

Every claim below is verified against source. Severities: **warning** = a fix
direction that will be a silent no-op, or a dropped finding; **suggestion** =
under-specified step.

---

## Confirmed sound (verified against source)

These are the load-bearing HIGH/MED findings; the plan's fix directions match the
code and the review.

- **B1 (upsert arity crash)** — verified. MDL calls `run_upsert/5` (apply
  arity-4) at `write_dispatch.ex:56` and `local_outbox/write.ex:246`, and
  `run_upsert/4` (apply arity-3) at `backfill.ex:83`, directly. AshSqlite exports
  `upsert/3` only (`ash_sqlite/lib/data_layer.ex:1296`); AshPostgres `upsert/4`
  only (`:3798`). The dispatcher `Ash.DataLayer.upsert/4`
  (`ash/lib/ash/data_layer/data_layer.ex:1003`) picks arity via
  `function_exported?(dl, :upsert, 4)` and falls back to the 3-arg apply — so
  A2's "replace direct calls with the dispatcher" fixes both layers. Correct.
- **#1 (RPC private-attribute exfiltration)** — verified. `fields.ex:104`
  `attribute?/2` is `Info.attribute(resource, name)` (matches private fields), so
  `to_select_and_load` (`:52`) folds any wire-named field into the select. R1's
  "resolve via `public_attribute`/`public_calculation`/…" is the right fix.
- **#2 (racing backfill resurrection)** — verified. `proven_coverage.ex:726` —
  after `Backfill.upsert_records` (`:715`) physically wrote `source_rows`,
  `Coverage.record` returning `:epoch_moved` only emits telemetry (`:727-729`);
  the just-written rows are never evicted. A3 #1 (evict `source_rows` + drop
  covering entries on `:epoch_moved`) is correct, and reuses the already-shipped
  `Invalidation.on_evict/3` (`proven_coverage.ex:800`, from the first plan's M-3
  fix).
- **#3 / B2 (tenant-key mismatch)** — verified. `write_dispatch.ex:78` keys
  invalidation on `changeset.tenant` (raw), while reads key coverage on
  `query.tenant` (Ash's converted `to_tenant`); the dispatcher even canonicalizes
  (`data_layer.ex:1005` `%{changeset | tenant: changeset.to_tenant}`). For a
  struct context-tenant the two never match. A1's single tenant-key helper using
  `to_tenant` is the right root fix.
- **#4 (sweeper doesn't exist)** — verified. Every "sweep" reference in `lib/` is
  a comment; `scheduler_cron: false` (`inject_outbox.ex:291`) disables ash_oban's
  own scheduler on the strength of a sweeper that has no module. A4's
  implement-or-re-enable decision is the only honest path.

The MED fix directions I sampled (#5 stale-check idempotence, #9/#12 in A6, #20
in A2, #16/#17/#18 in A5) are consistent with the cited line numbers and the
review's reasoning. The dependency graph (A1 tenant → A3/A4/A5; A2 dispatch →
A3/A6; R1 → A6) is correct, and the one cross-repo coupling (A6 auth taxonomy
needs R1's 401/403 mapping) is named in the landing order.

---

## Warning

### W1 — `Ash.DataLayer.transaction` is a no-op on AshSqlite; the plan's atomicity guarantees and the shipped rebase cleanup rely on it

`ash_sqlite/lib/data_layer.ex:450` hardcodes `def can?(_, :transact), do: false`.
`Ash.DataLayer.transaction/4` (the shell) runs the fun **bare** when the layer
doesn't export `transaction/4` (it falls to `{:ok, fun.()}`), so on an AshSqlite
resource — the outbox on the flagship generated stack (`gen.outbox` emits
`data_layer: AshSqlite.DataLayer`) and the typical local layer — there is **no
transaction**. The second review flagged this precisely as a LOW ("`rebase/2`
'all-or-nothing transaction' is a no-op on ash_sqlite … Use the co-commit Ecto
repo directly"), but this plan's LOW disposition section neither fixes nor defers
it — it's dropped. That matters in three places:

1. **The shipped rebase cleanup is already a no-op.** `destroy_captured_chain`
   (`api.ex:262`) wraps its `Ash.destroy!` calls in
   `Ash.DataLayer.transaction(outbox, …)`, and its comment (`:250-252`) claims an
   in-transaction raise "rolls back (destroying nothing)." On AshSqlite that is
   false — the fun runs bare, a mid-loop raise destroys the newest-first prefix
   up to the failure. It happens to be *safe* only because the destroy order is
   newest-seq-first / parked-head-last (`:253-255`), so a partial failure still
   leaves the parked blocker — but the transaction is theatrical and the
   `RebaseCleanupError` message ("nothing was destroyed") mis-describes the real
   state. This LOW should be dispositioned (fix the mechanism or fix the
   comments/message), not silently dropped.
2. **A5 #4 (refresh TOCTOU) needs a *real* transaction.** The dirty-check + upsert
   must be atomic; if implemented via `Ash.DataLayer.transaction` on an AshSqlite
   local layer, it is a no-op and the TOCTOU (#13) stays open. The load-bearing
   choice is the Ecto repo transaction.
3. **A5 #7 / A0 #16 (discard/drop_chain transactional destroy)** — same risk if
   the implementer reaches for `Ash.DataLayer.transaction`.

**Fix direction.** Standardize on the co-commit Ecto repo transaction, which
already works and is already in the codebase: `write.ex:332` (`co_commit_repo/3`)
resolves the shared repo, and `write.ex:314` uses `repo.transaction(fn -> … end)`
**directly** (bypassing Ash's `can?(:transact)` gate — that is exactly why the
async write path's co-commit is real while the rebase cleanup's is not). A5 #4/#7
should say "co-commit `repo.transaction`" explicitly and cite that helper, and
the dropped LOW should be folded into A5 #7 (correct `destroy_captured_chain` to
use `co_commit_repo.transaction`, or — if the ordering-based safety is accepted
as sufficient — fix the misleading comment and error message to match what
actually happens on AshSqlite).

---

## Suggestion

### S1 — A1's attribute-strategy tenant-key derivation is under-specified

A1 #1 says attribute-strategy records "under a strategy-consistent key rather than
mixing `nil`, raw values, and `:__global__`," but doesn't name the derivation.
This is the harder half of B2 (the review notes attribute tenancy makes
invalidation *structurally inert*, not just mis-keyed): Ash never calls
`set_tenant` for attribute strategy (`ash/lib/ash/query/query.ex:4653`, per the
review), so `query.tenant` is `nil` on reads while `changeset.tenant` is the
attribute value on writes. The helper must extract the tenant from the record's
multitenancy attribute (`Ash.Resource.Info.multitenancy_attribute/1` +
`Map.get(record, attr)`) for both the read and write paths to key identically —
and A0 #3's attribute-tenancy repro is what proves it. Spell out the extraction
so the helper is implementable in one pass; as written, "strategy-consistent key"
is a goal, not a step.

---

## Notes

- **Coverage is complete.** I mapped all 11 HIGH (#1–#8, A1, B1, B2) and all 17
  MED (#9–#27, A2–A5, B3) to a phase; every one is addressed. The LOW triage
  (fix-in-phase vs. defer) is reasonable, with the one exception (W1's dropped
  rebase-transaction LOW).
- **The A0 gate is correctly specified** ("each repro fails on the current code
  for the reviewed reason"), and Implementation note 5 (if a finding turns out
  already-fixed, keep the regression test and mark verified) is the right hedge,
  since the first plan's fixes have shipped and the second review explicitly
  scopes itself to *new* findings.
- **The `Invalidation.on_evict/3` reuse in A3** correctly builds on the
  first plan's shipped reconcile fix (`proven_coverage.ex:800`) rather than
  re-deriving it.

---

## Summary

**0 critical, 1 warning, 1 suggestion.** The plan is comprehensive and its fix
directions are sound for the findings I traced (B1, #1, #2, #3/B2, #4 all
verified). The one substantive issue is W1: `Ash.DataLayer.transaction` is a
no-op on AshSqlite, so the plan's atomicity guarantees (A5 #4 refresh TOCTOU,
#7 discard transaction) and the already-shipped rebase cleanup must use the
co-commit Ecto `repo.transaction` (proven at `write.ex:314`), and the dropped
rebase-transaction LOW must be dispositioned. Fix the transaction mechanism
choice and the attribute-tenant derivation detail, and the plan is ready.
