defmodule TodoClient.Remote.User do
  use Ash.Resource,
    domain: TodoClient.Remote.Domain,
    data_layer: AshRemote.DataLayer,
    extensions: [AshRemote.Resource]

  remote do
    source("TodoServer.User")
    schema_version("1.0.0")
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true, allow_nil?: false)
  end

  relationships do
    has_many(:lists, TodoClient.Remote.TodoList,
      public?: true,
      source_attribute: :id,
      destination_attribute: :user_id
    )
  end

  calculations do
    calculate :list_count, :integer, expr(not is_nil(id)) do
      public?(true)
    end
  end

  actions do
    create :create do
      primary?(true)
      accept([:name])
    end

    read :read do
      primary?(true)
    end
  end
end
