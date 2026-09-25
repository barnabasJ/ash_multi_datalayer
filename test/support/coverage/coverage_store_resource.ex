defmodule AshMultiDatalayer.Test.Coverage.CoverageStoreResource do
  @moduledoc """
  A minimal two-ETS-layer MDL resource with `coverage_store:` configured —
  proves the ledger persists via a real `Ash.read!` (not a hand-built
  `Coverage.insert/3` call), and that
  `AshMultiDatalayer.Orchestrator.ProvenCoverage.child_specs/1` restores it
  after the in-memory ledger is wiped (simulating a BEAM restart).
  """
  use Ash.Resource,
    domain: AshMultiDatalayer.Test.Coverage.CoverageTestDomain,
    data_layer: AshMultiDatalayer.DataLayer

  multi_data_layer do
    layer(:cache, Ash.DataLayer.Ets)
    layer(:source, Ash.DataLayer.Ets)
    read_order([:cache, :source])
    write_order([:source, :cache])

    orchestrator(
      {AshMultiDatalayer.Orchestrator.ProvenCoverage,
       coverage_store: AshMultiDatalayer.Test.Coverage.TestStoreEntry}
    )
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end
