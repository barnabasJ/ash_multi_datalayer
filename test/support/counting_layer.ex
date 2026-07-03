defmodule AshMultiDatalayer.Test.CountingLayer do
  @moduledoc """
  Generates a data-layer module that delegates every `Ash.DataLayer` callback
  the wrapped module exports, counting I/O callbacks in a public ETS table:

      defmodule CountingPostgres do
        use AshMultiDatalayer.Test.CountingLayer, wraps: AshPostgres.DataLayer
      end

  Only callbacks the wrapped module exports are defined, so Ash's
  `function_exported?` guards see the same surface as the wrapped layer.
  """

  @table :amdl_test_layer_calls
  @counted [
    :run_query,
    :run_aggregate_query,
    :create,
    :update,
    :destroy,
    :upsert,
    :bulk_create,
    :update_query,
    :destroy_query
  ]

  defmacro __using__(opts) do
    wraps = Macro.expand(Keyword.fetch!(opts, :wraps), __CALLER__)
    Code.ensure_compiled!(wraps)

    defs =
      for {name, arity} <- Ash.DataLayer.behaviour_info(:callbacks),
          function_exported?(wraps, name, arity) do
        args = Macro.generate_arguments(arity, __MODULE__)

        bump =
          if name in @counted do
            quote do
              AshMultiDatalayer.Test.CountingLayer.bump(__MODULE__, unquote(name))
            end
          end

        quote do
          def unquote(name)(unquote_splicing(args)) do
            unquote(bump)
            unquote(wraps).unquote(name)(unquote_splicing(args))
          end
        end
      end

    quote do
      (unquote_splicing(defs))
    end
  end

  @doc "Creates the shared counter table. Call once from test_helper."
  def ensure_table! do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public, write_concurrency: true])
    end

    :ok
  end

  @doc false
  def bump(module, callback) do
    :ets.update_counter(@table, {module, callback}, 1, {{module, callback}, 0})
    :ok
  end

  @doc "Count of calls to `callback` (or all counted callbacks) on `module`."
  def count(module, callback \\ nil)

  def count(module, nil) do
    :ets.select(@table, [{{{module, :_}, :"$1"}, [], [:"$1"]}]) |> Enum.sum()
  end

  def count(module, callback) do
    case :ets.lookup(@table, {module, callback}) do
      [{_, n}] -> n
      [] -> 0
    end
  end

  @doc "Resets all counters."
  def reset! do
    :ets.delete_all_objects(@table)
    :ok
  end
end
