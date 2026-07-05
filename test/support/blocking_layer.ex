defmodule AshMultiDatalayer.Test.BlockingLayer do
  @moduledoc """
  Delegates every `Ash.DataLayer` callback the wrapped module exports (modeled
  on `AshMultiDatalayer.Test.CountingLayer`), but can park `run_query` on a
  message from the arming test process — for deterministically reproducing
  read/write races without sleeps.

  The park happens **after** delegating: `run_query` captures the target's
  result first, parks, then returns the captured result. Parking before
  delegating would fetch post-write values on resume and the race would not
  reproduce (fix-plan review-2 F12).

  Usage — fully message-based, no polling:

      BlockingLayer.arm(MyBlockingLayer)
      task = Task.async(fn -> Ash.read!(query) end)
      assert_receive {:blocking_layer_parked, MyBlockingLayer, reader_pid}, 1000
      # ... do the racing write here ...
      BlockingLayer.release(MyBlockingLayer, reader_pid)
      result = Task.await(task)
  """

  @table :amdl_test_blocking_layer

  defmacro __using__(opts) do
    wraps = Macro.expand(Keyword.fetch!(opts, :wraps), __CALLER__)
    Code.ensure_compiled!(wraps)

    defs =
      for {name, arity} <- Ash.DataLayer.behaviour_info(:callbacks),
          name != :run_query,
          function_exported?(wraps, name, arity) do
        args = Macro.generate_arguments(arity, __MODULE__)

        quote do
          def unquote(name)(unquote_splicing(args)) do
            unquote(wraps).unquote(name)(unquote_splicing(args))
          end
        end
      end

    run_query_def =
      if function_exported?(wraps, :run_query, 2) do
        quote do
          def run_query(query, resource) do
            result = unquote(wraps).run_query(query, resource)
            AshMultiDatalayer.Test.BlockingLayer.maybe_park(__MODULE__)
            result
          end
        end
      end

    quote do
      (unquote_splicing(defs))
      unquote(run_query_def)
    end
  end

  @doc "Creates the shared coordination table. Call once from test_helper."
  def ensure_table! do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public, write_concurrency: true])
    end

    :ok
  end

  @doc "Clears any leftover arm/park state (call from test setup)."
  def reset! do
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  Arms `module` to park the NEXT `run_query` call reached on it. Must be
  called from the process that will `assert_receive` the parked notification
  and later `release/2` (the "test process" in the usage example).
  """
  def arm(module) do
    :ets.insert(@table, {{module, :armed_by}, self()})
    :ok
  end

  @doc false
  def maybe_park(module) do
    case :ets.take(@table, {module, :armed_by}) do
      [{_, test_pid}] ->
        send(test_pid, {:blocking_layer_parked, module, self()})

        receive do
          {:blocking_layer_release, ^module} -> :ok
        end

      [] ->
        :ok
    end
  end

  @doc "Releases a reader parked on `module`, identified by the pid from the parked notification."
  def release(module, reader_pid) do
    send(reader_pid, {:blocking_layer_release, module})
    :ok
  end
end
