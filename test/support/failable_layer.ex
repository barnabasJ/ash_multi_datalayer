defmodule AshMultiDatalayer.Test.FailableLayer do
  @moduledoc """
  A LocalOutbox replication-target stand-in: delegates every `Ash.DataLayer`
  callback to a wrapped layer (default `Ash.DataLayer.Ets`, so pushes are
  inspectable), but can be armed to fail `upsert`/`destroy` with a tagged error
  (`:rejected` → parks immediately; `:transient` → retries then parks) or to
  raise a conflict — for deterministic flush-triage tests without a real network.

      use AshMultiDatalayer.Test.FailableLayer, wraps: Ash.DataLayer.Ets

      FailableLayer.fail(MyRemote, :rejected)   # next writes return {:error, {:rejected, _}}
      FailableLayer.clear(MyRemote)             # writes delegate normally again
  """
  @table :amdl_test_failable_layer

  defmacro __using__(opts) do
    wraps = Macro.expand(Keyword.get(opts, :wraps, Ash.DataLayer.Ets), __CALLER__)
    Code.ensure_compiled!(wraps)

    passthrough =
      for {name, arity} <- Ash.DataLayer.behaviour_info(:callbacks),
          name not in [:upsert, :destroy],
          function_exported?(wraps, name, arity) do
        args = Macro.generate_arguments(arity, __MODULE__)

        quote do
          def unquote(name)(unquote_splicing(args)) do
            unquote(wraps).unquote(name)(unquote_splicing(args))
          end
        end
      end

    quote do
      (unquote_splicing(passthrough))

      def upsert(resource, changeset, keys, identity \\ nil) do
        AshMultiDatalayer.Test.FailableLayer.guard(__MODULE__, fn ->
          unquote(wraps).upsert(resource, changeset, keys, identity)
        end)
      end

      def destroy(resource, changeset) do
        AshMultiDatalayer.Test.FailableLayer.guard(__MODULE__, fn ->
          unquote(wraps).destroy(resource, changeset)
        end)
      end
    end
  end

  def ensure_table! do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:public, :named_table, :set])
    end

    :ok
  end

  @doc "Arm the layer to fail the next writes with `spec` (`:rejected` | `:transient`)."
  def fail(layer, spec), do: :ets.insert(@table, {layer, spec})

  @doc "Disarm the layer — writes delegate normally."
  def clear(layer), do: :ets.delete(@table, layer)

  @doc false
  def guard(layer, delegate) do
    case :ets.lookup(@table, layer) do
      [{^layer, :rejected}] -> {:error, {:rejected, "target rejected the write"}}
      [{^layer, :transient}] -> {:error, {:transient, "target transiently unavailable"}}
      _ -> delegate.()
    end
  end
end
