# B3 — `tenant_from_filter/2` is dead code — attribute-tenancy invalidation inert

- **Status**: OPEN — **two-phase (pass-7)**: Phase 1 lands the canonical tenant
  function (before H5/M2/L3/P4 are worked); B3 then stays OPEN and closes only
  in Phase 2, after the tenant-unit consumers are updated and the
  **four-bucketing-call-site** cross-cutting assertion passes (loop-3: four, not
  five — target calls are excluded, see the assertion below). "Lands first" ≠
  "closes first".
- **Severity**: Blocker (permanent stale cache)
- **Repo**: MDL (ash_multi_datalayer)
- **Verification**: VERIFIED
- **Source**:
  [20260707 implementation review — B3](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Original findings**: B2 (second review), #3, A5
- **Plan ref**: Workstream A phase A1 item 1; accepted review item S1
- **Files**: `lib/ash_multi_datalayer/tenant_key.ex:44-73` (untracked file)
- **Lead task for the tenant unit** — consumers
  [H5](h5-localoutbox-nil-tenant-model.md),
  [M2](m2-context-tenancy-raw-metadata-tenant.md),
  [L3](l3-write-through-drain-create-pk-tenant.md) (tenant half), and
  [P4](p4-global-tenant-invalidation.md) depend on B3 and consume its canonical
  function verbatim

## Defect

`tenant_from_filter/2` derives the attribute-tenancy read partition by
**regexing `inspect(filter, limit: :infinity)`** for `attr...value: X`. An
`%Ash.Filter{}` inspects as `#Ash.Filter<org_id == "acme">` — the substring
`value:` never appears — so the function **always returns `nil`**. Reads record
coverage under `:__global__` while writes invalidate under `TenantKey.changeset`
→ `Map.get(record, attr)` (the concrete value). The partitions never meet.

Even if the regex matched, it is unsound: returns integer/uuid/atom tenants as
_strings_ (`"42"` ≠ `42`) vs the typed write-side key; `[^,}\]]+` truncates `in`
lists; greedy match picks the wrong predicate in multi-predicate/`or` filters;
unanchored attr substring collides (`org` matches `organization_id`).

## Failure scenario

Attribute-strategy multitenancy, tenantless read `filter(org_id == "acme")` →
coverage recorded under `:__global__`; every write for `"acme"` bumps the
`"acme"` epoch and evicts physical rows there; the `:__global__` entry survives
forever → next read is a **permanent stale/missing cache hit**. Exactly original
finding B2, unresolved. Suites stayed green because they run the single-tenant
SQLite stack.

## Fix

The plan and accepted review item S1 specified the design: derive from
`Ash.Resource.Info.multitenancy_attribute/1` + `Map.get(record, attr)` on read
rows — **not** filter-inspect parsing. Correct implementation: structural walk
of the filter AST for an `Eq` on the tenant attribute, or extraction from
returned rows.

**Zero-row reads (pass-2 review F3)**: row extraction alone cannot cover an
empty result — an attribute-tenant read for `org_id == "acme"` that returns no
rows would still record coverage in the wrong partition and then serve a stale
miss after a later create for `"acme"`. So either the structural AST walk must
work for empty results, or the implementation must conservatively refuse to
record tenant-scoped coverage when the tenant cannot be proven.

**Canonical representation (binding, see the index)**: ONE shared function maps
every tenant representation to the canonical **partition string** (matching what
outbox entries already store), and every path — read coverage, write
invalidation, outbox filters, notifications — calls it. The review's `"42" ≠ 42`
complaint is a _consistency_ defect: it is resolved by both sides using the
shared function, not by preserving raw types ad hoc. No ad-hoc
`to_string`/`inspect` anywhere.

**B3 is the lead task for the tenant unit (technical review F2)**: it is the
_first tenant-unit fix after [PRE](pre-checkpoint-commit.md)_ and lands the
canonical function before H5/M2/L3/P4 are worked, with a pinned signature and
normalization rules, so those four consume it verbatim rather than each
re-deriving a "canonical" helper (which could five-way-diverge on an edge case
their individual repros miss). (PRE checkpoints the existing untracked
`tenant_key.ex` as a baseline; B3 then rewrites the tenant derivation on top —
"first" means first tenant-unit _fix_, not the first commit in the tracker.) Two
normalization points that MUST be pinned in the function and not left to each
consumer:

- **integer/atom → string**: use `to_string/1` (so `:foo → "foo"`, `42 → "42"`),
  NOT `inspect/1` (which gives `":foo"`). Document the choice in the function.
- **unscoped sentinel**: reconcile the read-side `:__global__` and H5's proposed
  `:all` into ONE value used everywhere; the index says "never `nil`". Pick one
  and make every path use it.

## Done when

- [ ] Repro test (plan A0 repro 3): attribute-strategy resource — a write
      invalidates the exact coverage partition a prior filtered read recorded;
      fails on unfixed code (read records `:__global__`)
- [ ] The canonical function (`TenantKey.canonical/2` or named equivalent) lands
      first (before H5/M2/L3/P4 are worked) with a pinned signature +
      normalization rules (integer/atom via `to_string`, single unscoped
      sentinel); H5/M2/L3/P4 cite B3 as their dependency and consume it verbatim
- [ ] Representation test: integer/uuid/atom tenant attribute values map to the
      SAME canonical partition key on the read and write sides (via the one
      shared function)
- [ ] **Cross-cutting assertion (holistic W2, scoped by loop-2)**: for one fixed
      tenant across all representations (struct via `Ash.ToTenant`, integer,
      atom, string, converted), the **four bucketing call sites** — read
      coverage, write invalidation, outbox chain filters, notifications — return
      the identical canonical **partition key**. This catches the divergence the
      per-consumer repros miss. NOTE: **target calls are NOT in this assertion**
      — they carry the real tenant value (concept 3 in the index), not the
      partition key; asserting they equal the partition string would be wrong
- [ ] Multi-predicate / `or` / `in` filters either derive correctly or
      conservatively refuse to partition (never wrong-partition)
- [ ] Zero-row repro: empty filtered read (`org_id == "acme"`, no rows) → later
      create for `"acme"` → re-read returns the new row (no stale miss from a
      wrong-partition coverage entry) — fails on unfixed code
- [ ] **Exact attribute identity, no regex/inspect (pass-7 Medium)**: the fix
      uses a structural filter-AST walk or extracted-row derivation with an
      **exact** tenant-attribute match — a more-careful regex-on-`inspect` patch
      is explicitly NOT an acceptable fix. Include an `org` vs `organization_id`
      substring-collision test (the wrong-attribute must not match)
- [ ] `INTEGRATION=1 mix test` green in MDL
