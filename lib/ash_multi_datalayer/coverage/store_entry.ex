defmodule AshMultiDatalayer.Coverage.StoreEntry do
  @moduledoc """
  Spark extension that turns any Ash resource into a persisted coverage-ledger
  store, backing `AshMultiDatalayer.Coverage.Store`. Add it to an app-owned
  resource on whatever data layer you already have:

      defmodule MyApp.Coverage.Entry do
        use Ash.Resource,
          domain: MyApp.Coverage,
          data_layer: AshSqlite.DataLayer,
          extensions: [AshMultiDatalayer.Coverage.StoreEntry]

        sqlite do
          table "amd_coverage_entries"
          repo MyApp.Repo
        end
      end

  No extension-level configuration is needed — every attribute and action the
  strategy relies on is injected automatically (`resource`, `tenant`,
  `fingerprint`, `normalised`, `filter`, `loaded_fields`, `loaded_at`; a
  `:record` upsert-create, the default `:read`, and the default `:destroy`).
  Point a resource's ProvenCoverage orchestrator at it:

      orchestrator {AshMultiDatalayer.Orchestrator.ProvenCoverage,
        coverage_store: MyApp.Coverage.Entry}

  Unlike `AshMultiDatalayer.Sync.OutboxEntry` (which requires a SQL layer
  because its flush jobs run on Oban), this extension imposes no data-layer
  requirement — the coverage store has no background jobs, so any
  `Ash.DataLayer` that supports plain attributes/create/read/destroy works.

  Generate one with `mix ash_multi_datalayer.gen.coverage_store`.
  """

  use Spark.Dsl.Extension,
    transformers: [AshMultiDatalayer.Coverage.Transformers.InjectStoreEntry]
end
