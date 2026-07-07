# Deferred follow-ups — explicitly parked, not lost

- **Status**: DEFERRED (each item needs its own decision before any release that
  depends on it)
- **Source**: plan
  [LOW disposition "Defer with explicit follow-up"](../../plans/20260706-second-review-findings-fix-plan.md);
  first-plan handoff out-of-scope list;
  [task-coverage review F4/F13](../../reviews/20260707-second-review-fixes-task-coverage-review.md)

These are known issues deliberately **not** in the open task tables. They are
recorded here so "the committed history is done" is never read as "nothing
remains". Promote an item to a task file when it's picked up.

## From the second-review plan's deferred list (MDL)

1. **Crash-safe pending/active ledger protocol** — check-insert-verify /
   commit-then-invalidate are not crash-safe; a recorder killed between insert
   and verify (or writer between commit and invalidate) leaves lasting stale
   coverage. Design: insert entries as inert `pending`, flip active after
   verify. Larger than the #2/A1 eviction fixes; needs its own design pass.
2. **Global cross-tenant ledger cap + epoch meta GC** — ledger growth is capped
   per-tenant only; epoch meta rows never GC'd.
3. **`Divergence` shadow-read epoch guarding** (`divergence.ex:37`) — not
   epoch-guarded → false-positive alarms operators learn to ignore.
4. **`HostResolver` persistent_term cache invalidation** after hot code reload —
   a resource added post-boot parks entries `:rejected`.

## From the second-review plan's deferred list (ash_remote)

5. **Server subscription revocation beyond documentation/hook** — anything that
   changes the public channel contract. (Docs/hook half is
   [L13](l13-ash-remote-server-realtime-lows.md).)
6. **Per-subscriber refetch coalescing component** — **conditional deferral**:
   this entry only takes effect after
   [L13](l13-ash-remote-server-realtime-lows.md) item 3 has tried the simple
   shared per-resource/per-PK cache (or measured the amplification and recorded
   the number here). It is not pre-deferred; do not skip the L13 attempt on the
   strength of this entry (pass-2 coverage review F8).

## First-plan handoff exclusions (M-7 / M-12) — still open by design

The 20260706 first-plan handoff explicitly excluded these; "M-1…M-12 / R-1…R-11
done" does **not** include them
([whole-repo review](../../reviews/20260706-whole-repo-review.md)):

7. **M-7 hit-path phantom absence during updates** — invalidation evicts the
   before-image row, then propagate re-upserts; a reader between the two sees a
   never-existed absence. The first plan only _documented_ the anomaly (A4 docs
   task); the actual fix (upsert-in-place for updates; evict only on
   destroy/PK-change) remains open.
8. **M-12 declared follow-up tests** — `SqlPassthrough` error-branch tests and
   `RemoteContext` flush-threading tests.

## Separate arcs (not findings — tracked elsewhere)

- Phase 4a `can?` consolidation (first plan's A5, "separate arc").
- `docs/design/20260706-atomic-capability-delegation-rfc.md` — sequenced after
  the Phase 4a consolidation.
- Stacked-orchestrators RFC (exploratory).
