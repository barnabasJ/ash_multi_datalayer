defmodule AshMultiDatalayer.Orchestrator do
  @moduledoc """
  The behaviour that defines how `AshMultiDatalayer.DataLayer` orchestrates
  reads, writes, and structural questions across a resource's declared layers.

  `AshMultiDatalayer.DataLayer` is a thin shell: it accumulates Ash's canonical
  query build into a `Query` struct, keeps the migration/codegen shim, and
  answers Ash's structural callbacks by delegating to the resource's configured
  orchestrator. The *policy* — which layer serves a read, how a write is
  propagated, which layer is authoritative — lives behind this behaviour.

  A resource selects its strategy in the DSL:

      multi_data_layer do
        orchestrator {AshMultiDatalayer.Orchestrator.ProvenCoverage, divergence_sampler: 0.05}
        layer :l1, Ash.DataLayer.Ets
        layer :l2, AshPostgres.DataLayer
        read_order [:l1, :l2]
        write_order [:l2, :l1]
      end

  The default strategy is `AshMultiDatalayer.Orchestrator.ProvenCoverage`
  (today's behaviour: reads served from an earlier layer only under a recorded
  coverage-ledger subsumption proof; synchronous invalidate-then-propagate
  writes). See the orchestrator-behaviour ADR for the full rationale.

  ## Callback groups

  - **data path** — `read/2`, `run_aggregate_query/3` (optional), `create/2`,
    `update/2`, `upsert/4`, `destroy/2`.
  - **structural** — `authority/1` (answers `source/1` and, from Phase 4a,
    `can?(:select)`), `transaction_layer/1` (answers `transaction/4`,
    `rollback/2`, `in_transaction?/1`), `can?/2` (returns a boolean, or
    `:default` to fall back to the shell's intersection semantics).
  - **inbound** — `handle_external_change/2` / `handle_external_gap/2`: reactions
    to changes that bypassed this node's write path (notification bridges).
  - **lifecycle** — `validate_opts/2` (compile-time opt validation, invoked by
    the `ValidateOrchestrator` verifier) and `child_specs/1` (processes the
    strategy needs, started under `AshMultiDatalayer.Supervisor`).
  """

  alias AshMultiDatalayer.DataLayer.Query

  # -- data path -------------------------------------------------------------

  @doc "Serve a read. Receives the accumulated `Query` struct and the resource."
  @callback read(Query.t(), Ash.Resource.t()) ::
              {:ok, [Ash.Resource.record()]} | {:error, term()}

  @doc "Run a top-level aggregate query (`Ash.DataLayer.run_aggregate_query/4`)."
  @callback run_aggregate_query(Query.t(), [Ash.Query.Aggregate.t()], Ash.Resource.t()) ::
              {:ok, term()} | {:error, term()}

  @callback create(Ash.Resource.t(), Ash.Changeset.t()) ::
              {:ok, Ash.Resource.record()} | {:error, term()}
  @callback update(Ash.Resource.t(), Ash.Changeset.t()) ::
              {:ok, Ash.Resource.record()} | {:error, term()}
  @callback upsert(
              Ash.Resource.t(),
              Ash.Changeset.t(),
              [atom()],
              Ash.Resource.Identity.t() | nil
            ) :: {:ok, Ash.Resource.record()} | {:error, term()}
  @callback destroy(Ash.Resource.t(), Ash.Changeset.t()) :: :ok | {:error, term()}

  # -- structural questions Ash asks that are really authority questions -----

  @doc "The layer that is the source of truth for reads (answers `source/1`)."
  @callback authority(Ash.Resource.t()) :: module()

  @doc "The layer that owns transactions (answers `transaction/4`, `rollback/2`)."
  @callback transaction_layer(Ash.Resource.t()) :: module()

  @doc """
  The strategy's answer to a `can?/2` capability question, or `:default` to fall
  back to the shell's intersection semantics (write features → `write_order`
  intersection, read features → `read_order` intersection, `:multitenancy` → all
  layers).
  """
  @callback can?(Ash.Resource.t(), Ash.DataLayer.feature()) :: boolean() | :default

  # -- inbound changes that bypassed this node's write path -------------------

  @doc """
  React to a per-record change that arrived out of band (e.g. an `ash_remote`
  realtime notification). ProvenCoverage invalidates matching coverage;
  LocalOutbox refreshes the local layer. *Implemented in Phase 4.*
  """
  @callback handle_external_change(Ash.Resource.t(), Ash.Notifier.Notification.t()) :: :ok

  @doc """
  React to a notification gap (resubscribe/join-denied — writes possibly
  missed). ProvenCoverage drops the ledger for resource+tenant; LocalOutbox runs
  a full reconcile. *Implemented in Phase 4.*
  """
  @callback handle_external_gap(Ash.Resource.t(), tenant :: term()) :: :ok

  # -- lifecycle -------------------------------------------------------------

  @doc "Validate the orchestrator's own opts at compile time."
  @callback validate_opts(Ash.Resource.t(), keyword()) :: :ok | {:error, String.t()}

  @doc """
  Child specs the strategy needs (drainers, table owners), started under
  `AshMultiDatalayer.Supervisor`. Receives the resources configured with this
  orchestrator, grouped as the supervisor discovers them.
  """
  @callback child_specs([Ash.Resource.t()]) :: [Supervisor.child_spec()]

  @optional_callbacks validate_opts: 2,
                      child_specs: 1,
                      run_aggregate_query: 3,
                      handle_external_change: 2,
                      handle_external_gap: 2
end
