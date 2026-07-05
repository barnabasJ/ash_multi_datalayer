# Review Addendum — C4: external invalidation leaves physical rows; coverage re-recording resurrects them

> **Fixed (2026-07-05), commit `ba7e3d0`:** both fix directions 1 (evict-on-write)
> and 2 (reconcile-on-record) landed together, per
> `docs/plans/critical-bugs-fix-plan.md` Phase 4; fix direction 3
> (`forget!`/`not_found?`) is public API on `AshMultiDatalayer`. Regression
> coverage: `test/integration/external_invalidation_test.exs` (the shapes
> below, both full-miss and remainder paths), `test/integration/forget_test.exs`,
> `test/integration/reconcile_scope_test.exs` (the documented scope boundary —
> reconcile heals the evict-failure residue, not a forgotten `on_write`), and
> the concurrency stress test's op mix. The downstream `../ash_remote_cache`
> stopgap (`CacheLayer.evict!`, the bridge's own `forget!`/`not_found?`) is
> now redundant and should fold onto this API — tracked outside this repo.

**Date:** 2026-07-05
**Relation to the 2026-07-04 review:** a new critical finding (numbered C4 to
follow C1–C3), discovered downstream while building `ash_remote_cache` (the
realtime-notification → invalidation bridge, `../ash_remote_cache`). Found and
reproduced *after* the review closed, so it is not in the main document. It
touches the same code region as C3 and should be folded into that work.

---

## C4. `Coverage.Invalidation.on_write/4` drops ledger entries but never the physical row — later coverage recording resurrects destroyed rows

**Severity:** critical — persistent stale reads (a *destroyed* row is served as
live), violating NFR2 ("never stale reads"). **Confidence:** high — reproduced
deterministically downstream (see "Downstream repro + stopgap" below), with the
mechanism hand-verified in `lib/` at the current commit. An *update* variant is
mechanism-verified but not yet reproduced (see below).

**Where:**

- `lib/ash_multi_datalayer/coverage.ex` / `Coverage.Invalidation.on_write/4` —
  the public API offered to external invalidation sources. It drops matching
  ledger entries only; it never touches the cache layer's physical storage.
- `lib/ash_multi_datalayer/backfill.ex:49-77` — `upsert_record/4` is strictly
  upsert-by-PK. Recording fresh coverage over a region never removes cached
  rows the source no longer returns.
- `lib/ash_multi_datalayer/data_layer.ex:742-817` — both the full-hit path
  (`coverage_read`) and the remainder path (`remainder_read`/`run_region`)
  serve rows by running the filter against the cache layer's physical storage
  whenever the ledger says "covered".

**Mechanism (destroy):**

1. A row is cached and covered. A destroy happens *outside* the local write
   path (flagship case: another client's write arriving as an `ash_remote`
   realtime notification). The external consumer does the documented thing and
   calls `on_write/4`.
2. `on_write/4` drops every ledger entry the row matches. The physical row
   stays in the cache layer's table. So far, still correct: nothing covers it.
3. Any later read whose filter matches the row misses, fetches from the source
   (which correctly does not return the destroyed row), backfills, and records
   coverage for its filter Q.
4. The next read of Q is a coverage hit — and the cache layer's filter run
   matches the stale physical row. The destroyed row is served as live. Via
   `coverage_split`'s union-of-all-entries, remainder reads of *unrelated*
   queries whose covered region contains the row serve it too (the downstream
   repro hit exactly this: a relationship-load's remainder read reusing an
   unrelated entry's coverage).

Staleness is persistent: there is no future source row to upsert over the
ghost, so nothing heals it short of LRU eviction or a coincidentally-matching
local write.

**Why MDL's own tests never see it:** local destroys go through
`WriteDispatch`, whose propagation step removes the row from cache layers
(`Backfill.destroy_record/4`). Only the external-invalidation path — the very
thing `on_write/4` is public *for* — skips physical removal. The API is unsound
for destroys as published: it breaks MDL's core invariant ("covered region ⇒
physical rows under it are fresh") and MDL's own read path is what serves the
resulting ghost.

**Update variant (mechanism-verified, not yet reproduced):** an external
*update* that moves a row out of a region has the same shape. The cache still
holds the old values; `on_write/4` drops the entries the before-state matched;
a later source read of that region records fresh coverage; the stale physical
row still matches the region's filter and is served with pre-update values.
This one *can* self-heal — any covered read of the row's *new* region upserts
the fresh values by PK — but nothing guarantees such a read ever happens.
Evict-on-destroy alone does not close this variant; the reconcile fix below
does.

**Fix direction (in MDL, in preference order):**

1. **Make `on_write/4` uphold the invariant itself:** on a destroy, also remove
   the physical row from the cache layers (`Backfill.destroy_record/4` already
   exists and is exactly this operation). External consumers then get correct
   behavior from the API they were already told to call.
2. **Reconcile on coverage recording** (defense in depth, and the only fix that
   covers the update variant): when recording coverage for filter Q after a
   source read, delete cached rows matching Q whose PK is not in the fetched
   set. Restores the invariant regardless of which invalidation source forgot
   what. Costs one extra cache-layer pass per backfill. Natural to build
   *with* the C3 epoch guard — same `maybe_backfill`/`Coverage.record` region,
   and both are "make recording safe against what happened meanwhile".
3. **Promote a public row-purge API** (`forget!`-style: evict physical row +
   drop matching ledger entries, by PK) for consumers that discover staleness
   out-of-band — e.g. a `NotFound` from a direct backend call after a
   notification was silently lost on an otherwise-healthy websocket, which
   lifecycle/heartbeat signals cannot detect. This currently lives downstream
   (see below) and had to reimplement `Delegate`'s filter-application logic to
   exist — a sign it belongs in MDL.

**Downstream repro + stopgap (to be folded back / removed once fixed here):**
`../ash_remote_cache` currently patches the destroy case on its side:

- `lib/ash_remote_cache/cache_layer.ex` — `evict!/3` (its moduledoc documents
  this finding's mechanism), plus the `Delegate`-mirroring point-query it
  needed.
- `lib/ash_remote_cache/invalidation_notifier.ex:73` — evicts on destroy, in
  addition to calling `on_write/4`.
- `lib/ash_remote_cache.ex` — `forget!/3` and `not_found?/1` (the pull-based
  self-heal of fix direction 3).
- End-to-end regression tests pinning the ghost scenario:
  `example/todo_client/test/todo_client/live_test.exs:52` and `:90` (assert a
  destroyed-elsewhere row no longer appears after `forget!`, including on a
  completely fresh mount).

Once fix 1 (and ideally 2) lands in MDL, the bridge's `evict!` call and most of
`CacheLayer` can be deleted, and `forget!`/`not_found?` should move here as
public API. Test-suite gap to add alongside C3's interleaving tests: an
external-invalidation destroy followed by a re-covering read (both the
same-filter and the unrelated-remainder shapes), and the update-moves-region
variant.

**Suggested fix-order placement:** with step 3 (C3) — same code region, same
"recording must not launder stale state" theme.
