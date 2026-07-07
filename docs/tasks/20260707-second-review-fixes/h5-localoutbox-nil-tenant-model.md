# H5 — Systemic LocalOutbox tenant model: `nil` = "IS NULL" vs "unscoped"

- **Status**: OPEN
- **Severity**: High (multitenant boot clobbers pending writes)
- **Repo**: MDL (ash_multi_datalayer)
- **Verification**: VERIFIED / AGENT
- **Source**:
  [20260707 implementation review — H5](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Original finding**: #19 (target-call half)
- **Plan ref**: Workstream A phase A5 item 3 (and A1 tenant canonicalization)
- **Files**: `lib/ash_multi_datalayer/orchestrator/local_outbox/api.ex:559-566`
  (`base_query`/`tenant_filter`), `:435-441` (`boot_hydrate`), `:308`
  (`resume_sync`), `:496-514` (`dirty?`/`outbox_nonempty?`); entries stringified
  at `write.ex:273`
- **Depends on**: [B3](b3-tenant-from-filter-dead-code.md) — consume B3's
  canonical tenant function verbatim; do not add a local normalization
- **Related tasks**: [M2](m2-context-tenancy-raw-metadata-tenant.md),
  [L3](l3-write-through-drain-create-pk-tenant.md),
  [P4](p4-global-tenant-invalidation.md) — the tenant unit

## Defect

`tenant \\ nil` is translated into `filter(is_nil(tenant))` — "tenant IS NULL" —
not "unscoped". But every entry for a multitenant host stores a stringified
tenant (`write.ex:273`), and `boot_hydrate/1` calls `hydrate/refresh` with no
tenant. So the nil-tenant queries see none of the real entries.

## Failure scenario

On a multitenant LocalOutbox host (permitted for ETS/Postgres local layers),
boot hydration with pending `tenant: "t1"` entries:
`outbox_nonempty?(resource, nil)` sees only `is_nil(tenant)` rows → reports
empty → `refresh(:all, nil)` bypasses the dirty-chain rule → pending local
updates are overwritten with stale remote state and pending local creates are
deleted; the entries later flush their snapshots → **silent local/remote
divergence**. Also: `resume_sync/1` only kicks the nil backlog (60s sweeper
latency); `status/1` can report `:synced` while entries are pending.
Single-tenant SQLite avoids all of this — hence green suites.

## Fix

Distinguish "unscoped / all tenants" from "tenant IS NULL" throughout the
LocalOutbox API, using **the unscoped sentinel chosen by B3** (the binding
decision reconciles read-side `:__global__` with `:all` — do not presuppose
`:all` here; B3 picks it, H5 consumes it). `boot_hydrate`, `resume_sync`,
`dirty?`, `outbox_nonempty?`, and `status` must either iterate tenant partitions
or run genuinely unscoped. Derive entry tenant keys from B3's one shared
canonical-partition-string function — do not add a local normalization.

## Done when

- [ ] Repro test (plan A0 repro 15): multitenant host, pending `"t1"` entries —
      boot hydrate does NOT bypass the dirty-chain rule; fails on unfixed code
      by clobbering the pending write
- [ ] `resume_sync` kicks tenant-scoped backlogs; `status` reflects pending
      tenant-scoped entries
- [ ] Entry-driven target calls carry the **real entry tenant** (concept 3 — a
      tenant value the target layer understands, e.g. `tenant: entry.tenant`),
      and chain filters carry the **partition key**; neither cross-interferes on
      colliding PKs (#19)
- [ ] Chain filters / bucketing use B3's shared canonical **partition-key**
      function and **B3's pinned unscoped sentinel** (H5 consumes it for scan
      scope — B3 owns/reconciles `:__global__`/`:all`, loop-3). Target calls do
      NOT use the partition string — no local tenant normalization anywhere else
      in the LocalOutbox API
- [ ] `INTEGRATION=1 mix test` green in MDL
