defmodule AshMultiDatalayer.Test.LocalOutbox.Migrations do
  @moduledoc false
  use Ecto.Migration

  def up do
    create table("lo_widgets", primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:name, :string)
      add(:count, :integer, default: 0)
      add(:updated_at, :integer, default: 0)
    end

    create table("lo_stale_widgets", primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:name, :string)
      add(:version, :integer, default: 1)
    end

    create table("lo_outbox", primary_key: false) do
      add(:seq, :integer, primary_key: true)
      add(:write_ref, :uuid, null: false)
      add(:resource, :string, null: false)
      add(:tenant, :string)
      add(:record_pk, :map, null: false)
      add(:op, :string, null: false)
      add(:payload, :map)
      add(:base_image, :map)
      add(:remote_snapshot, :map)
      add(:target, :string, null: false)
      add(:state, :string, null: false, default: "pending")
      add(:error_class, :string)
      add(:last_error, :map)
      add(:parked_at, :utc_datetime_usec)
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end
  end

  def down do
    drop(table("lo_widgets"))
    drop(table("lo_stale_widgets"))
    drop(table("lo_outbox"))
  end
end
