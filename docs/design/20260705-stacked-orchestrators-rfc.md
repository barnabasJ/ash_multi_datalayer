# RFC: Stacked orchestrators — composing strategies pairwise over shared pivot layers

**Status**: Exploratory draft — design direction only, **not scheduled**
(post-v1 of the [extraction + LocalOutbox arc](../plans/orchestrator-extraction-and-local-outbox-plan.md))
**Date**: 2026-07-05 **Author**: Barnabas Jovanovics
**Depends on**: [Orchestrator behaviour ADR](./20260705-orchestrator-behaviour-adr.md),
[LocalOutbox RFC](./20260705-local-outbox-orchestrator-rfc.md)

## Problem

One resource, three layers, two *different* consistency relationships:

```
L1 (ETS hot cache)  ── proven-coverage caching ──  L2 (SQLite local store)
L2 (SQLite local store) ── local-authoritative async sync ── L3 (remote backend)
```

A single orchestrator cannot express this: ProvenCoverage assumes its last
layer is the source of truth; LocalOutbox assumes its first layer is. The
composition wants ProvenCoverage *between* L1 and L2 and LocalOutbox
*between* L2 and L3. This RFC sketches how strategies compose pairwise —
**stages** over shared **pivot** layers — so this stack (and multi-tier
caches like ETS→Redis-class→PG) become declarable without a bespoke
three-layer strategy per combination.

## Why this particular composition is well-defined

The load-bearing observation: **the boundary layer is the authority on both
sides.** ProvenCoverage's authority is its *last* layer; LocalOutbox's is its
*first*. When they share L2, the outer stage's "source of truth" is exactly
the inner stage's "local truth", and three things follow:

1. **Reads compose with zero semantic change.** ProvenCoverage's
   fall-through/source/remainder reads against L2 *are* LocalOutbox reads
   (local-only, complete copy). Each stage's correctness argument — coverage
   subsumption, the C1–C4 invariants, divergence sampling — stays local to
   the stage and references its own source. No new global proof obligations
   arise on the read path.
2. **Writes compose innermost-out.** The inner stage performs the
   synchronous authoritative write (L2 commit + L3 enqueue, per LocalOutbox);
   the outer stage consumes the returned record as its authoritative-write
   result (invalidate L1 coverage, propagate to L1, per ProvenCoverage).
   FR3.6 is preserved at every level: each stage only ever sees the record
   the layer below *returned*.
3. **The inbound glue already exists.** The inner stage's out-of-band pivot
   writes — `refresh/3`, `discard_local/1`, hydration — are, from the outer
   stage's perspective, precisely **external changes**: writes that bypassed
   its write path. The `handle_external_change/2` / `handle_external_gap/2`
   callbacks added for the notification bridge are the composition seam: the
   stack coordinator subscribes each stage's out-of-band writes and gap
   events to its *outer neighbour's* callbacks. The full inbound story then
   composes end to end: remote notification → LocalOutbox refreshes L2 →
   bubbles up as an external change → ProvenCoverage invalidates matching L1
   coverage.

## Sketch: DSL and composition contract

```elixir
multi_data_layer do
  layer :hot,    Ash.DataLayer.Ets
  layer :local,  AshSqlite.DataLayer
  layer :remote, AshRemote.DataLayer

  orchestration do
    stage {AshMultiDatalayer.Orchestrator.ProvenCoverage, ledger_max_entries: 512},
      over: [:hot, :local]
    stage {AshMultiDatalayer.Orchestrator.LocalOutbox,
      outbox_resource: MyApp.Sync.OutboxEntry}, over: [:local, :remote]
  end
end
```

Single-stage resources keep today's flat `orchestrator ...` DSL untouched;
`orchestration do ... end` is the multi-stage form (one of the two, never
both).

**The pivot rule (verifier-enforced).** Stages are ordered outermost →
innermost. Adjacent stages must share exactly one layer, and that layer must
be the outer stage's *source* (its `authority/1`) **and** the inner stage's
*authority*. Compositions that violate it are rejected at compile time —
e.g. LocalOutbox-over-ProvenCoverage is incoherent (the outer stage would
replicate asynchronously *into* a layer the inner stage treats as a
derived cache).

**Structural answers.** The *global* authority is the innermost stage's
synchronous authority (L2 above): `source/1`, `can?(:select)`,
`transaction_layer/1` answer from it. `can?/2` composes stage-wise with the
shell's documented intersection fallback. Kill switch, pause, telemetry, and
`mix ash_multi_datalayer.inspect` grow a stage dimension (engage/pause a
stage, tag events with it).

**The boundary port (the one refactor this needs).** Stages must not reach
the far side of their boundary by reading `read_order`/`write_order`
positionally — in a stack, "read my source" means "invoke the next stage's
read", and "write my authority" means "invoke the next stage's write". Each
stage therefore receives an injectable **boundary port** (a reader/writer
pair; the flat case injects the raw layer, the stacked case injects the
next stage). This is a contained refactor of both strategies *if* their
far-boundary access is already funneled through one internal function each —
which the extraction phase should ensure as cheap forward-compat (see the
plan's Phase 1 note), without building the port itself.

## The correctness obligation stacking adds

Exactly one: **no pivot mutation without notification.** Every write to a
pivot layer must either flow through the outer stage's write path or emit an
external-change event to it — otherwise the outer stage serves stale
coverage silently. The pivot's writers are enumerable (inner write path,
refresh, discard_local, hydrate, kill-switch write-through) and the property
is testable with the wrapper-layer harness: *instrument the pivot; assert
every observed mutation is paired with an outer-stage write invocation or
`handle_external_change/2` call.* This property test is the acceptance gate
for any stacking implementation.

## Scope discipline

- v1 of stacking (when scheduled): **exactly two stages**, and exactly the
  ProvenCoverage-over-LocalOutbox composition — the local-first client with
  a hot cache. Every additional composition (ProvenCoverage-over-
  ProvenCoverage multi-tier caching; chained LocalOutbox relay sync) ships
  only with its own pivot-rule argument and test suite.
- Not in the current implementation arc at all. It depends on the
  extraction, both strategies, and the inbound-callback surface having
  landed and settled; scheduling it now would bloat a plan whose Phase 0–8
  are already substantial. The only concession the current arc makes is the
  Phase 1 forward-compat funneling note.
- Demand-gated: the design is recorded because the seam decisions (boundary
  port, external-change bubbling) are cheap now and expensive later; the
  implementation waits for a concrete user of the three-layer stack.

## Open questions

1. Does the `orchestration`/`stage` DSL subsume the flat form (a single
   `stage` over all layers) or stay a parallel syntax? Leaning subsume-at-
   parse-time, flat syntax sugar-preserved.
2. Stage-scoped operator tooling: does the kill switch engage per stage, per
   resource, or both? Per-stage pause for LocalOutbox is already `pause_sync`;
   ProvenCoverage's stage disable should map to today's kill-switch meaning.
3. Transactions spanning the outer stage: ProvenCoverage today answers
   `:transact` from the source of truth — in a stack that is the pivot, whose
   own writes (enqueue co-commit) already transact on the same repo. Confirm
   the nesting behaves under ash_sqlite savepoints.
4. Does `await/2` bubble? (Probably yes trivially — the ref lives on the
   record metadata regardless of which stage returned it.)

## Links

- [Orchestrator behaviour ADR](./20260705-orchestrator-behaviour-adr.md) —
  the behaviour this composes; `handle_external_change/2` as the glue.
- [LocalOutbox RFC](./20260705-local-outbox-orchestrator-rfc.md) — inner
  stage of the motivating stack; its "Inbound changes" section defines the
  out-of-band writes that must bubble.
- [Implementation plan](../plans/orchestrator-extraction-and-local-outbox-plan.md)
  — Phase 1 carries the forward-compat funneling note; stacking itself is
  out of scope there.

---

**Last Updated**: 2026-07-05
