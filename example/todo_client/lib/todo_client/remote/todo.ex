defmodule TodoClient.Remote.Todo do
  use Ash.Resource,
    domain: TodoClient.Remote.Domain,
    data_layer: AshMultiDatalayer.DataLayer,
    extensions: [AshRemote.Resource]

  multi_data_layer do
    layer(:cache, Ash.DataLayer.Ets)
    layer(:remote, AshRemote.DataLayer)

    read_order([:cache, :remote])
    write_order([:remote, :cache])
  end

  remote do
    source("TodoServer.Todo")
    schema_version("1.0.0")
  end

  attributes do
    attribute(:completed, :boolean, public?: true)
    attribute(:due_date, :date, public?: true)
    uuid_primary_key(:id)
    attribute(:inserted_at, :utc_datetime_usec, public?: true)
    attribute(:priority, TodoClient.Remote.Priority, public?: true)
    attribute(:title, :string, public?: true, allow_nil?: false)
  end

  relationships do
    belongs_to(:list, TodoClient.Remote.TodoList,
      public?: true,
      attribute_writable?: true,
      source_attribute: :list_id,
      destination_attribute: :id
    )

    belongs_to(:parent, TodoClient.Remote.Todo,
      public?: true,
      attribute_writable?: true,
      source_attribute: :parent_id,
      destination_attribute: :id
    )

    has_many(:subtasks, TodoClient.Remote.Todo,
      public?: true,
      source_attribute: :id,
      destination_attribute: :parent_id
    )
  end

  validations do
    validate(string_length(:title, min: 3))
  end

  calculations do
    # Mirrored server expression (regenerated from the manifest): the cache
    # layer can evaluate this from a covered row, so ash_multi_datalayer's
    # local evaluation computes it with no source round trip.
    calculate :overdue?,
              :boolean,
              expr(not is_nil(due_date) and due_date < today() and not completed) do
      public?(true)
    end
  end

  actions do
    create :create do
      primary?(true)
      accept([:title, :completed, :priority, :due_date, :list_id, :parent_id])
    end

    destroy :destroy do
      primary?(true)
      require_atomic?(false)
    end

    read :read do
      primary?(true)
    end

    update :update do
      primary?(true)
      require_atomic?(false)
      accept([:title, :completed, :priority, :due_date, :list_id, :parent_id])
    end
  end
end
