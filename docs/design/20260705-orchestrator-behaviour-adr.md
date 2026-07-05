# 20260705-Orchestrator-Behaviour-ADR

**Status**: Proposed **Date**: 2026-07-05 **Deciders**: Barnabas Jovanovics

## Decision Drivers

- The read/write routing policy is currently hardcoded: the read decision tree
  lives in `AshMultiDatalayer.DataLayer.run_query/2` and the write pipeline in
  `AshMultiDatalayer.WriteDispatch`. A second policy (local-authoritative with
  asynchronous replication — see the
  [LocalOutbox RFC](./20260705-local-outbox-orchestrator-rfc.md)) cannot be
  added without forking both.
- The supporting machinery (`Coverage`, `Backfill`, `ValueMerge`, `Delegate`,
  `SqlPassthrough`, `Capability`, `KillSwitch`, `Telemetry`) is already
  decoupled from the policy — the extraction moves *policy*, not mechanism.
- "Which layer is the source of truth" leaks beyond `run_query`: `source/1`,
  `can?(:select)`, `transaction/rollback/in_transaction?`, and the
  write-feature `can?` intersection all encode the answer positionally
  (`List.last(read_order)` / `hd(write_order)`). A strategy that inverts
  authority (local layer authoritative) must be able to answer these
  differently.
- No Hex release has shipped, so DSL reshuffling has zero compatibility cost.
  This window closes at v1 release.

## Context

The library was designed around one consistency strategy: reads served from an
earlier layer only under a coverage-ledger subsumption proof, writes applied
synchronously to the authoritative layer and propagated to the rest
([generic-ordered-layers ADR](./20260417-generic-ordered-layers-adr.md),
FR3.5/FR3.6). Discussion of a local-first use case (local layer authoritative,
remote layer an asynchronously synced store) showed that a second strategy is a
different *orchestration* of the same layers and the same mechanisms — not a
different data layer. Strategy naming discussion also settled a convention:
**strategies are named after their distinguishing mechanism, not their use-case
category** ("caching" and "local-first" are categories that several strategies
can serve; e.g. a future stale-while-revalidate strategy is also a caching
strategy).

## Decision

**Extract the orchestration policy into an `AshMultiDatalayer.Orchestrator`
behaviour, selected per resource in the DSL. `AshMultiDatalayer.DataLayer`
becomes a thin shell (DSL, query accumulation, structural delegation); the
current behaviour moves wholesale into
`AshMultiDatalayer.Orchestrator.ProvenCoverage`, the default. Strategy modules
are named after their distinguishing mechanism.**

### Behaviour surface

```elixir
defmodule AshMultiDatalayer.Orchestrator do
  alias AshMultiDatalayer.DataLayer.Query

  # -- data path -----------------------------------------------------------
  @callback read(Query.t(), Ash.Resource.t()) ::
              {:ok, [Ash.Resource.Record.t()]} | {:error, term()}
  @callback run_aggregate_query(Query.t(), [Ash.Query.Aggregate.t()], Ash.Resource.t()) ::
              {:ok, term()} | {:error, term()}

  @callback create(Ash.Resource.t(), Ash.Changeset.t()) ::
              {:ok, Ash.Resource.Record.t()} | {:error, term()}
  @callback update(Ash.Resource.t(), Ash.Changeset.t()) ::
              {:ok, Ash.Resource.Record.t()} | {:error, term()}
  @callback upsert(Ash.Resource.t(), Ash.Changeset.t(), [atom()], Ash.Resource.Identity.t() | nil) ::
              {:ok, Ash.Resource.Record.t()} | {:error, term()}
  @callback destroy(Ash.Resource.t(), Ash.Changeset.t()) :: :ok | {:error, term()}

  # -- structural questions Ash asks that are really authority questions ----
  # Answers source/1 (Ecto schema source) and can?(:select).
  @callback authority(Ash.Resource.t()) :: module()
  # Answers transaction/4, rollback/2, in_transaction?/1.
  @callback transaction_layer(Ash.Resource.t()) :: module()
  # :default falls back to the shell's intersection semantics
  # (write features → write_order intersection, read features → read_order
  # intersection, :multitenancy → all layers).
  @callback can?(Ash.Resource.t(), Ash.DataLayer.feature()) :: boolean() | :default

  # -- inbound changes that bypassed this node's write path ------------------
  # Invoked by notification bridges (e.g. the ash_remote realtime bridge —
  # ../ash_remote_cache's successor) so the reaction lives in the strategy
  # and the bridge stays pure transport. Strategy-defined semantics:
  # ProvenCoverage invalidates matching coverage / drops the ledger on a gap;
  # LocalOutbox refreshes the local layer / runs a full reconcile (see its
  # RFC's "Inbound changes" section).
  @callback handle_external_change(Ash.Resource.t(), Ash.Notifier.Notification.t()) :: :ok
  @callback handle_external_gap(Ash.Resource.t(), tenant :: term()) :: :ok

  # -- lifecycle -------------------------------------------------------------
  # Validates the orchestrator's own opts at compile time (invoked by the
  # ValidateOrchestrator verifier).
  @callback validate_opts(Ash.Resource.t(), keyword()) :: :ok | {:error, String.t()}
  # Processes the strategy needs (drainers, table owners), started under
  # AshMultiDatalayer.Supervisor. Receives the resources configured with this
  # orchestrator, grouped as the supervisor discovers them.
  @callback child_specs([Ash.Resource.t()]) :: [Supervisor.child_spec()]

  @optional_callbacks validate_opts: 2,
                      child_specs: 1,
                      run_aggregate_query: 3,
                      handle_external_change: 2,
                      handle_external_gap: 2
end
```

### DSL

```elixir
multi_data_layer do
  # Spark type {:spark_behaviour, AshMultiDatalayer.Orchestrator}:
  # accepts Module or {Module, opts}. Default: ProvenCoverage.
  orchestrator {AshMultiDatalayer.Orchestrator.ProvenCoverage,
    divergence_sampler: 0.05}

  layer :l1, Ash.DataLayer.Ets
  layer :l2, AshPostgres.DataLayer
  read_order [:l1, :l2]
  write_order [:l2, :l1]
end
```

**Strategy-specific options move out of the section schema into orchestrator
opts.** `ledger_max_entries`, `divergence_sampler`, `local_evaluation?`,
`local_evaluation_overrides`, `fold_aggregates?`, `fold_aggregate_overrides`,
`sql_join_aggregates?`, and `sql_join_aggregate_overrides` are ProvenCoverage
concepts, not multi-layer concepts; a LocalOutbox resource must not carry a
dead `divergence_sampler` knob. The section keeps only what every strategy
shares: `layer` entities, `read_order`, `write_order`, `orchestrator`.
`Info` grows `orchestrator/1` → `{module, opts}`; ProvenCoverage reads its own
opts through it.

Orchestrator opts are also where each strategy names its **state resources**
(LocalOutbox's `outbox_resource`, ProvenCoverage's `ledger_resource`) — per
the [sync-state-as-Ash-resources ADR](./20260705-sync-state-as-ash-resources-adr.md),
strategy state lives in app-owned Ash resources rather than private library
storage, and `validate_opts/2` is where each strategy checks the configured
resource implements its contract extension.

### What stays in the shell (`AshMultiDatalayer.DataLayer`)

- The Spark DSL section, `Query` struct, and all query-building callbacks
  (`filter/sort/limit/…` accumulation) — these are mechanical replay
  bookkeeping, identical for every strategy.
- The SQL-passthrough second heads on the build callbacks and the
  `set_context/3` subquery flip. Whether the flip *applies* becomes an
  orchestrator question: the shell consults
  `Info.orchestrator/1` and only attempts `SqlPassthrough.build/3` for
  strategies that declare it (ProvenCoverage, per `sql_join_aggregates?`).
- The `read_from:` context escape hatch (per-action targeted read for
  state comparison — see the LocalOutbox RFC's "Per-action layer
  targeting"): the shell short-circuits to the named layer, side-effect-free,
  before any orchestrator is consulted — it is strategy-independent by
  construction. **Shipping note** (plan-review D5): this bullet describes
  where the mechanism *lives architecturally*; it is new behaviour and
  ships in the plan's **Phase 4a**, not with the Phase 1 extraction — the
  same existing-vs-future distinction as the capability derivation below. Write-side context (`write_through:`) is the opposite: it
  passes through to the orchestrator, which interprets it per its own
  semantics.
- Structural callbacks (`source/1`, `can?/2`, `transaction/4`, …) as thin
  delegations to `authority/1`, `transaction_layer/1`, `can?/2` with the
  documented `:default` fallback. **The shell hardcodes no capability
  answers** (revised 2026-07-05 — the original draft kept
  joins/combinations/bulk-atomic unconditionally false in the shell "for
  any strategy", which LocalOutbox disproved: a join inside a complete,
  authoritative local layer bypasses nothing). Capability answers are
  **derived per strategy from the underlying layers**, per feature class:
  - *authority-only* — features that only ever execute on the strategy's
    authority (`:select`, `{:lock,_}`, `:transact`); `source/1` likewise.
  - *serving-set* — read-expressiveness features answer from the authority,
    and the strategy checks the actual serving layer per query (the
    `Capability` module pattern), degrading to the authority when an
    earlier layer can't execute the shape.
  - *all-layers* — `:multitenancy` stays an intersection: a layer that
    cannot isolate tenants would leak data.
  - *write features* — the authority's answers, plus a verify-time check
    that propagation targets accept PK-upsert/destroy (all they receive).
  - *bypass-guards* — hardcoded `false` survives only where `true` would
    route work around orchestration inside a single layer
    (`update_query`/`destroy_query`/`{:atomic,_}`/bulk/`:combine`; joins
    under ProvenCoverage, where joined rows escape the coverage proof) —
    **even when the layer itself says true** (ash_sqlite advertises
    `update_query`); each guard documents its reason, per strategy.
- Migration/codegen (`AshMultiDatalayer.Migration`) — keyed off declared
  layers, orchestrator-independent.

### What moves

- The whole `run_query/2` decision tree, aggregate fold/join dispatch,
  remainder/merged/source reads, and backfill policy →
  `Orchestrator.ProvenCoverage`.
- `WriteDispatch` (authoritative write → invalidate → propagate) →
  ProvenCoverage's write callbacks. The module can survive as a private
  helper of ProvenCoverage; it is no longer a public seam.
- **Kill-switch semantics.** The shell no longer short-circuits; each
  orchestrator defines what "disabled" means and consults `KillSwitch`
  itself. For ProvenCoverage: exactly today's behaviour (reads to source,
  invalidation still runs, propagation skipped). Each strategy's ADR/RFC must
  document its kill-switch meaning explicitly.

### Verifiers

Spark resolves verifiers at `use` time, so the list stays static. Each
strategy-specific verifier (e.g. `ValidateSolverSupportedPredicates`,
`RejectFieldPolicies`' fall-through rationale) reads `Info.orchestrator/1`
from the DSL state and **no-ops when it doesn't apply** to the configured
strategy. A new `ValidateOrchestrator` verifier checks the module implements
the behaviour and invokes its `validate_opts/2`. Which verifiers apply to
which strategy is part of each strategy's design doc.

### Naming convention

Shipped strategies are named for their distinguishing mechanism:

- `Orchestrator.ProvenCoverage` — reads served locally only under a recorded
  subsumption proof; synchronous invalidate-then-propagate writes (today's
  behaviour).
- `Orchestrator.LocalOutbox` — local layer authoritative; writes replicated
  asynchronously through an ordered outbox (see its RFC).
- A future stale-while-revalidate strategy would be
  `Orchestrator.StaleWhileRevalidate` — the convention holds.

Category names (`Cache`, `LocalFirst`) are reserved for documentation prose,
never module names: multiple strategies can serve one category, and the first
module to squat a category name makes every later sibling misleading. Users
may point `orchestrator` at any module implementing the behaviour.

## Consequences

### Positive

1. A second strategy is additive: new module + its verifier applicability
   list, no fork of the read/write paths.
2. Authority inversion becomes expressible — the prerequisite for LocalOutbox.
3. The DSL stops advertising ProvenCoverage knobs on resources that don't use
   ProvenCoverage.
4. Kill-switch, `can?`, and transaction semantics get per-strategy definitions
   instead of accidental positional ones.
5. Users can implement bespoke orchestrators against a documented behaviour.

### Negative

1. One more indirection layer in every data-path call (negligible: a
   compile-time-resolvable `Info.orchestrator/1` dispatch).
2. The behaviour is a public API surface we must keep stable after v1 —
   callback additions need `@optional_callbacks` + defaults.
3. Verifier no-op-per-strategy is easy to forget when adding a strategy;
   `ValidateOrchestrator` and each strategy's design doc carry the checklist.
4. Documentation (README, guides, technical doc) must be rewritten around the
   orchestrator concept before release.

### Mitigations

- The extraction is a **pure refactor gated on the full suite**: ProvenCoverage
  must be behaviourally identical to today (the full unit + property suite —
  ~97 tests at `b290e0d`, post fix-plan hardening; the earlier "~126" figure
  was wrong (plan-review B2) — **plus the `INTEGRATION=1` suite**, green and
  unchanged). No functional change rides along.
- Sequencing: the critical-bug fixes
  ([fix plan](../plans/critical-bugs-fix-plan.md)) land *before* the
  extraction — C1–C4/M1 live in exactly the code that moves, and refactoring
  around known-broken code doubles the review surface.

## Alternatives Considered

### Alternative 1: Fine-grained policy hooks instead of a whole-orchestrator behaviour

Small callbacks (`serve_read_from(query) :: {:layer, l} | {:split, plan}`,
`after_write/3`, …) on one shared pipeline.

- Good, because more code reuse between strategies.
- Bad, because the ProvenCoverage decision tree does not factor into small
  hooks (coverage probe, remainder split, merged read, aggregate dispatch are
  interlocked), and LocalOutbox wants a genuinely different write path
  (enqueue, not propagate). The hook surface would be shaped by exactly one
  strategy and fight the next one.

**Why not**: wrong altitude; shared mechanisms already live in library modules
both strategies call.

### Alternative 2: Strategy enum in the DSL (`strategy :proven_coverage | :local_outbox`)

- Good, because simpler discovery.
- Bad, because it re-introduces the closed enum the
  [generic-ordered-layers ADR](./20260417-generic-ordered-layers-adr.md)
  deliberately removed, and blocks user-supplied strategies.

**Why not**: the DSL already chose open composition over enums.

### Alternative 3: Separate data-layer modules per strategy

`AshMultiDatalayer.DataLayer` vs `AshMultiDatalayer.LocalFirstDataLayer`.

- Good, because zero shared-shell design work.
- Bad, because it duplicates the DSL, query accumulation, migration shim, and
  every structural callback; divergence between the copies is guaranteed.

**Why not**: the shell is the part that is genuinely identical.

## Validation

- The extraction commit shows ProvenCoverage green against the unchanged test
  suite (pure-refactor gate).
- LocalOutbox lands as a second implementation without modifying the shell's
  data-path code — the proof the seam is real.

## Links

- [LocalOutbox RFC](./20260705-local-outbox-orchestrator-rfc.md) — the second
  strategy driving this extraction.
- [Sync-state-as-Ash-resources ADR](./20260705-sync-state-as-ash-resources-adr.md)
  — how strategy state is stored (app-owned Ash resources) and async work
  executed (Oban via ash_oban).
- `../ash_remote_cache` — today hardcodes the ProvenCoverage reaction
  (invalidate / gap-drop); the `handle_external_change/2` +
  `handle_external_gap/2` callbacks exist so the notifier/guard become thin
  transport serving both strategies. Decision (2026-07-05): no separate
  package — the utilities fold into **ash_remote** itself, and the
  ash_remote_cache example becomes the flagship mixed-strategy example (see
  the LocalOutbox RFC's "Inbound changes" and the plan's fold-in + example
  phases).
- [Implementation plan](../plans/orchestrator-extraction-and-local-outbox-plan.md)
  — phased delivery of the extraction, LocalOutbox, and the local-first
  example.
- [Generic-ordered-layers ADR](./20260417-generic-ordered-layers-adr.md) —
  naming/enum precedent.
- [No-write-behind-in-v1 ADR](./20260417-no-write-behind-in-v1-adr.md) —
  constraints any asynchronous strategy must respect.
- [Critical-bugs fix plan](../plans/critical-bugs-fix-plan.md) — sequenced
  before this refactor.
- On acceptance: add decision-log rows to the
  [PRD](./ash-multi-datalayer-prd.md) (orchestrator behaviour; mechanism
  naming; strategy opts out of the section schema; per-strategy kill-switch
  semantics).

---

**Last Updated**: 2026-07-05
