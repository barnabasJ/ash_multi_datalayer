defmodule TodoClient.Remote.TodoList do
  use Ash.Resource,
    domain: TodoClient.Remote.Domain,
    data_layer: AshMultiDatalayer.DataLayer,
    extensions: [AshRemote.Resource]

  multi_data_layer do
    layer(:cache, Ash.DataLayer.Ets)
    layer(:remote, AshRemote.DataLayer)

    read_order([:cache, :remote])
    write_order([:remote, :cache])

    # Showcase both aggregate paths side by side: `todo_count` is folded from
    # the cached todos (0 RPC when they're covered), while `completed_count` is
    # opted out of folding — handed to the remote layer, which forwards it to
    # the server by name (an RPC). Same page, two aggregates, two strategies.
    fold_aggregate_overrides([:completed_count])
  end

  remote do
    source("TodoServer.TodoList")
    schema_version("1.0.0")
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true, allow_nil?: false)
  end

  relationships do
    has_many(:todos, TodoClient.Remote.Todo,
      public?: true,
      source_attribute: :id,
      destination_attribute: :list_id
    )

    belongs_to(:user, TodoClient.Remote.User,
      public?: true,
      attribute_writable?: true,
      source_attribute: :user_id,
      destination_attribute: :id
    )
  end

  actions do
    create :create do
      primary?(true)
      accept([:name, :user_id])
    end

    read :read do
      primary?(true)
    end
  end

  aggregates do
    count :completed_count, :todos do
      public?(true)
      filter(expr(completed))
    end

    count :todo_count, :todos do
      public?(true)
    end
  end
end
