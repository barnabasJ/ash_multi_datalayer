defmodule TodoClient.Test.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource TodoClient.Test.SampledTodo
  end
end

defmodule TodoClient.Test.SampledTodo do
  @moduledoc """
  A twin of `TodoClient.Remote.Todo` with the divergence sampler at 1.0 —
  every cache hit is shadow-checked against the server. Kept separate so the
  demo resources stay deterministic (exact RPC-count assertions) while
  divergence detection is still proven end to end.
  """
  use Ash.Resource,
    domain: TodoClient.Test.Domain,
    data_layer: AshMultiDatalayer.DataLayer,
    extensions: [AshRemote.Resource]

  multi_data_layer do
    layer(:cache, Ash.DataLayer.Ets)
    layer(:remote, AshRemote.DataLayer)

    read_order([:cache, :remote])
    write_order([:remote, :cache])
    divergence_sampler(1.0)
  end

  remote do
    source("TodoServer.Todo")
    schema_version("1.0.0")
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true)
    attribute(:completed, :boolean, public?: true)
  end

  actions do
    read :read do
      primary?(true)
    end
  end
end
