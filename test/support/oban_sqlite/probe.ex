defmodule AshMultiDatalayer.Test.ObanSqlite.Probe do
  @moduledoc """
  A tiny ETS side-channel the skeleton's flush action writes to, so tests can
  observe what happened inside an Oban worker process (which Oban instance ran a
  flush — `job.conf.name` — and how many times the action body executed). Keyed
  by the entry's `ref`.
  """
  @table :amd_oban_sqlite_probe

  def ensure! do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:public, :named_table, :set])
    end

    :ok
  end

  @doc "Record `{instance_name, run_count}` for a ref; run_count accumulates."
  def record(ref, instance) do
    count = :ets.update_counter(@table, {ref, :runs}, 1, {{ref, :runs}, 0})
    :ets.insert(@table, {{ref, :instance}, instance})
    count
  end

  def instance(ref), do: lookup({ref, :instance})
  def runs(ref), do: lookup({ref, :runs}) || 0

  def reset!, do: :ets.delete_all_objects(@table)

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> nil
    end
  end
end
