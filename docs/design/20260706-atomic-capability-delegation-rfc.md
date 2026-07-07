# RFC: Atomic capability delegation — support per-record atomics by routing them to the authority layer

**Status**: Follow-up draft — accepted direction ("support as many atomic
features as possible"), **not scheduled**; sequence **after** Phase A5 of the
[2026-07-06 fix plan](../plans/20260706-review-findings-fix-plan.md) (the Phase
4a `can?` consolidation), so the delegation is implemented once in the
strategies, not twice across the shell duplication A5 deletes. **Date**:
2026-07-06 **Author**: Barnabas Jovanovics **Depends on**:
[Orchestrator behaviour ADR](./20260705-orchestrator-behaviour-adr.md),
[LocalOutbox RFC](./20260705-local-outbox-orchestrator-rfc.md)

## Problem

MDL refuses `{:atomic, _}` blanket-`false` in three places (ProvenCoverage
`can?`, LocalOutbox `can?`, and the shell's `default_can?` — the last is Phase
4a duplication slated for deletion), grouped with the orchestration-bypass
guards (`update_query`, `destroy_query`, `bulk_create`, joins). The recorded
rationale: features that "route work around orchestration inside a single layer"
bypass the write dispatcher + invalidation (ProvenCoverage) or enqueue no outbox
entries (LocalOutbox).

That rationale is airtight for **query-shaped mutations** but **over-broad for
per-record atomics**. The consequences of the blanket refusal today:

- Ash 3 update actions default `require_atomic? true`; on an MDL resource users
  must either accept the non-atomic fallback (where Ash permits it) or set
  `require_atomic? false` per action — friction on every update action.
- The refusal reintroduces application-level read-modify-write races that atomic
  increments exist to prevent: two concurrent `score + 1` updates through the
  fallback path can lose an increment **at the source itself**.

## Key insight

The bypass danger is _losing sight of the write_, not the atomic expression. For
a **single-record** atomic, MDL does not lose sight of anything:

1. Ash still calls MDL's `update/2` (or `upsert`) callback — the changeset
   carries the atomic; the orchestrator stays in the loop.
2. The executing layer returns the materialized record (`RETURNING *` semantics)
   — MDL receives the **after-image**.
3. The only thing an atomic denies is a _client-side prediction_ of the result —
   and neither strategy needs one (see below). The before-image available
   (`changeset.data`) is exactly as trustworthy as on today's non-atomic path;
   no new staleness is introduced.

## Design sketch

### ProvenCoverage

Route the atomic-carrying changeset to the **source of truth** (where writes go
first anyway). On return:

- `Invalidation.on_write(resource, tenant, changeset.data, returned_record)` —
  unchanged machinery; before-image trust identical to the non-atomic path.
- `WriteDispatch.propagate/…` pushes the **materialized** record to the cache
  layers — they never see the atomic expression, which is exactly propagation's
  existing contract.

Capability answer becomes a delegation: `can?(resource, {:atomic, kind})` → the
source layer's answer. A cache-only `write_order` (no SQL source) keeps
answering `false`.

### LocalOutbox

Run the atomic on the **local layer** (ash_sqlite supports atomics). Build the
outbox entry's snapshot from the **returned record** instead of pre-materialized
changeset values. Replication is already value-based (PK-upserts of snapshots,
never operation replay), so nothing is lost relative to the current model.

Documented semantic caveat: the atomic evaluates against **local** state; an
offline client's `score + 1` replicates as a value snapshot that can conflict
with concurrent remote increments. That is precisely what
`conflict_detection: {:stale_check, field}` catches — it parks as a `:conflict`
rather than silently losing the increment. Say this loudly in the guide's
LocalOutbox section.

Interaction with the fix plan's `write_through` guard (A1-2): once atomics are
supported, `write_through` **cannot** materialize them client-side for the
targets-first push (`apply_attributes` does not evaluate atomics). Either
write_through keeps rejecting atomic changesets (guard stays, documented), or it
gets a special order for atomics only (local-first with a fallback outbox
entry). Default: keep the rejection; revisit on demand.

### What stays refused

**Query-shaped mutations** (`update_query`, `destroy_query`, bulk paths) mutate
rows the orchestrator never enumerates — no per-row images return.

- ProvenCoverage _could_ support them with coarse invalidation (drop the whole
  tenant partition + epoch bump — the same "no reliable before-image" fallback
  upserts already use), trading cache efficiency for correctness. Optional,
  opt-in if ever; not part of this RFC's first cut.
- LocalOutbox cannot: outbox chains and dirty-chain bookkeeping need a PK per
  entry, and a query mutation yields PKs only under `return_records?`, which
  defeats the query path's purpose. Permanently refused.

## Open questions / verify before implementing

1. **Exact capability shapes Ash probes** — `{:atomic, :update}`,
   `{:atomic, :upsert}`, `:expr_error`, and how `require_atomic?` interacts with
   a data layer that answers `true` for some kinds and `false` for others.
   Enumerate from Ash source at implementation time.
2. **Upsert atomics** — `upsert/4` in both strategies has its own path
   (LocalOutbox flush uses PK-upserts); confirm whether atomic upserts arrive
   through the same seam and whether the replication target (`ash_remote`) needs
   anything (it should not — targets receive materialized values; the wire
   protocol never carries expressions).
3. **Friction measurement** — check how Ash behaves today when MDL answers
   `false` (fallback-with-warning vs error per action shape). If real usage is
   already tripping on `require_atomic?`, raise this RFC's priority.
4. **Calculated/expression defaults inside atomics** referencing fields the
   cache holds — none expected to matter (the source evaluates), but confirm the
   returned record satisfies `Coverage.needed_fields` for propagation (it
   returns the full row; select-narrowing on writes would need a check).

## Acceptance shape (when scheduled)

Repro-first, per the house rule: a failing test that an atomic update through an
MDL resource (a) executes atomically at the authority (assert no
read-modify-write against a concurrent writer — two racing `+1`s both land), (b)
invalidates/propagates (ProvenCoverage: covered read returns the new value;
LocalOutbox: outbox entry snapshot carries the computed value), and (c) parks a
conflict when an offline atomic races a remote change to the stale-check field.
