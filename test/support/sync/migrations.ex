defmodule AshMultiDatalayer.Test.Sync.Migrations do
  @moduledoc false

  defmodule OutboxTable do
    @moduledoc false
    use Ecto.Migration

    # Matches the shape the OutboxEntry extension injects (atoms stored as TEXT,
    # maps as JSON). `seq` is the autoincrementing INTEGER PRIMARY KEY.
    def up do
      create table("amd_test_outbox", primary_key: false) do
        add :seq, :integer, primary_key: true
        add :write_ref, :uuid, null: false
        add :resource, :string, null: false
        add :tenant, :string
        add :record_pk, :map, null: false
        add :op, :string, null: false
        add :payload, :map
        add :base_image, :map
        add :remote_snapshot, :map
        add :target, :string, null: false
        add :state, :string, null: false, default: "pending"
        add :error_class, :string
        add :last_error, :map
        add :parked_at, :utc_datetime_usec
        add :inserted_at, :utc_datetime_usec, null: false
        add :updated_at, :utc_datetime_usec, null: false
      end
    end

    def down, do: drop(table("amd_test_outbox"))
  end
end
