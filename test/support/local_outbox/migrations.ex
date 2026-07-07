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

    # stale-check on a NON-JSON-native field (datetime) — the base image round-trips
    # through the outbox `:map`/JSON, so its value comes back a string; regression
    # guard that a clean flush does not falsely compare string vs %DateTime{}.
    create table("lo_stamp_widgets", primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:name, :string)
      add(:seen_at, :utc_datetime_usec)
    end

    create table("lo_timestamp_widgets", primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:name, :string)
      add(:inserted_at, :utc_datetime_usec)
    end

    create table("lo_ifempty_widgets", primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:name, :string)
    end

    create table("lo_failable_local_widgets", primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:name, :string)
    end

    create unique_index("lo_failable_local_widgets", [:name])

    create table("lo_mt_widgets", primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:org_id, :string)
      add(:name, :string)
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
    drop(table("lo_stamp_widgets"))
    drop(table("lo_timestamp_widgets"))
    drop(table("lo_ifempty_widgets"))
    drop(table("lo_failable_local_widgets"))
    drop(table("lo_mt_widgets"))
    drop(table("lo_outbox"))
  end
end
