defmodule AshMultiDatalayer.Test.FailableLayer do
  @moduledoc """
  A LocalOutbox replication-target stand-in: delegates every `Ash.DataLayer`
  callback to a wrapped layer (default `Ash.DataLayer.Ets`, so pushes are
  inspectable), but can be armed to fail `upsert`/`destroy` with a tagged error
  (`:rejected` → parks immediately; `:transient` → retries then parks;
  `:forbidden` → an `%Ash.Error.Forbidden{}`, parks immediately as `:auth`) or
  to raise a conflict — for deterministic flush-triage tests without a real
  network.

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
          name not in [:upsert, :destroy, :run_query],
          function_exported?(wraps, name, arity) do
        args = Macro.generate_arguments(arity, __MODULE__)

        quote do
          def unquote(name)(unquote_splicing(args)) do
            unquote(wraps).unquote(name)(unquote_splicing(args))
          end
        end
      end

    # H3: opt-in read failure — `run_query` normally always passes through
    # (armed writes must not also break reads other tests rely on, e.g. a
    # target read inside `check_stale/2` while `upsert`/`destroy` is armed to
    # fail); `fail_reads/2` is a SEPARATE, explicit arm so it never surprises
    # existing write-failure tests.
    run_query_def =
      if function_exported?(wraps, :run_query, 2) do
        quote do
          def run_query(query, resource) do
            AshMultiDatalayer.Test.FailableLayer.guard_read(__MODULE__, fn ->
              unquote(wraps).run_query(query, resource)
            end)
          end
        end
      end

    # Data layers disagree on `upsert`'s arity (`Ash.DataLayer.Ets` takes an
    # `identity`, `AshSqlite.DataLayer` doesn't) — call whichever `wraps`
    # actually implements, never a hardcoded arity.
    upsert_def =
      if function_exported?(wraps, :upsert, 4) do
        quote do
          def upsert(resource, changeset, keys, identity \\ nil) do
            AshMultiDatalayer.Test.FailableLayer.guard(__MODULE__, fn ->
              unquote(wraps).upsert(resource, changeset, keys, identity)
            end)
          end
        end
      else
        quote do
          def upsert(resource, changeset, keys) do
            AshMultiDatalayer.Test.FailableLayer.guard(__MODULE__, fn ->
              unquote(wraps).upsert(resource, changeset, keys)
            end)
          end
        end
      end

    quote do
      (unquote_splicing(passthrough))
      unquote(run_query_def)
      unquote(upsert_def)

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

  @doc "Arm the layer to fail the next writes with `spec` (`:rejected` | `:transient` | `:forbidden`)."
  def fail(layer, spec), do: :ets.insert(@table, {layer, spec})

  @doc "Disarm the layer — writes delegate normally."
  def clear(layer), do: :ets.delete(@table, layer)

  @doc false
  def guard(layer, delegate) do
    case :ets.lookup(@table, layer) do
      [{^layer, :rejected}] -> {:error, {:rejected, "target rejected the write"}}
      [{^layer, :transient}] -> {:error, {:transient, "target transiently unavailable"}}
      [{^layer, :forbidden}] -> {:error, %Ash.Error.Forbidden{}}
      _ -> delegate.()
    end
  end

  @doc """
  Arm the layer to fail its NEXT read (`run_query`) with `reason` — separate
  from `fail/2` (writes) so arming one never surprises a test relying on the
  other still working (H3: proving a local-read failure during LocalOutbox
  refresh reconciliation surfaces as `{:error, _}`, not a raise/`MatchError`).
  """
  def fail_reads(layer, reason), do: :ets.insert(@table, {{layer, :reads}, reason})

  @doc "Disarm the layer's read failure — reads delegate normally again."
  def clear_reads(layer), do: :ets.delete(@table, {layer, :reads})

  @doc false
  def guard_read(layer, delegate) do
    case :ets.lookup(@table, {layer, :reads}) do
      [{_, reason}] -> {:error, reason}
      [] -> delegate.()
    end
  end
end
