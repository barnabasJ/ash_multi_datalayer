# L1 — Composite-PK crash in aggregate fold paths (A4 partial)

- **Status**: DONE — `add_aggregates_via_layer/5` now keys by
  `Map.take(row, primary_key)` (full-PK map) instead of
  `[pk] = primary_key(resource)`, matching a single-attribute PK's behavior
  while also working for composite PKs. `pk_merge/3` hardened the same way for
  consistency, even though its only caller (`remainder_applicable?/2`) gates it
  to single-PK resources already (confirmed still guarded-unreachable for
  composite PKs; not a live bug there). New `CompositePkAuthor` fixture
  (2-attribute PK: `id` + `tenant`) with a relationship aggregate over
  `TestPost`, forced onto the fold path via `sql_join_aggregate_overrides`
  (same-repo SQL would otherwise let ash_sql's native aggregate-subquery
  passthrough compute it inside one SQL statement, never reaching
  `add_aggregates_via_layer/5` at all). 1 repro test: fails with `MatchError` on
  unfixed code (confirmed via stash), passes with the fix.
  `INTEGRATION=1 mix test` green (319, up from 318).
- **Severity**: Low (loud crash on legitimate query)
- **Repo**: MDL (ash_multi_datalayer)
- **Verification**: VERIFIED
- **Source**:
  [20260707 implementation review — L1](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Original finding**: A4 (fixed only in reconcile/scan paths)
- **Plan ref**: Workstream A phase A3 item 5
- **Files**: `lib/ash_multi_datalayer/orchestrator/proven_coverage.ex:406-420`
  (`add_aggregates_via_layer`), `pk_merge` ~line 598

## Defect

`[pk] = Ash.Resource.Info.primary_key(resource)` still crashes for composite-PK
resources with relationship aggregates. A4 was fixed in the reconcile/scan paths
only; the aggregate fold paths were missed.

## Fix

Use `Map.take(row, primary_key)` / full-PK keying in `add_aggregates_via_layer`
(the reachable fold path), as done in the reconcile paths (plan A3 item 5).

**`pk_merge/3` is guarded-unreachable for composite PKs (loop-5 review,
source-verified)**: its only caller is behind `remainder_applicable?/2`
(`proven_coverage.ex:545-551`), which requires
`match?([_], Ash.Resource.Info.primary_key(resource))` — i.e. **single-PK
only**. A composite-PK read never reaches `pk_merge/3`, so its `[pk] =` (`:597`)
can't crash in production; it is defensive/latent, not a live bug. Do NOT write
a "composite-PK exercises `pk_merge`" repro — it is impossible on current code
(the query is guarded out first). Optionally harden `pk_merge`'s `[pk] =` to
full-PK keying for consistency, but that is not a fail-first behavior fix.

## Done when

- [ ] Repro test: composite-PK resource with a relationship aggregate reads
      through the **fold path** (`add_aggregates_via_layer/5`) without
      `MatchError` — fails on unfixed code (verify this path is actually
      reachable for composite PKs; if it too is guarded single-PK, reclassify
      the whole task as defensive-hardening, not a live crash)
- [ ] `pk_merge/3`: optional defensive hardening only — no impossible
      composite-PK repro required (guarded unreachable, per above)
- [ ] `INTEGRATION=1 mix test` green in MDL
