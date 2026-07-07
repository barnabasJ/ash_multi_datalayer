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
            AshMultiDatalayer.Test.FailableLayer.guard_upsert(__MODULE__, fn ->
              unquote(wraps).upsert(resource, changeset, keys, identity)
            end)
          end
        end
      else
        quote do
          def upsert(resource, changeset, keys) do
            AshMultiDatalayer.Test.FailableLayer.guard_upsert(__MODULE__, fn ->
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

  @doc """
  Arm the layer to fail the next writes with `spec` (`:rejected` |
  `:transient` | `:forbidden` | `:not_found` — M6: mirrors a remote-layer
  NotFound-class destroy failure, e.g. `AshRemote.DataLayer`'s translation
  of a server-side "already gone" response).
  """
  def fail(layer, spec), do: :ets.insert(@table, {layer, spec})

  @doc "Disarm the layer — writes delegate normally."
  def clear(layer), do: :ets.delete(@table, layer)

  @doc false
  def guard(layer, delegate) do
    run_before_write(layer)

    case :ets.lookup(@table, layer) do
      [{^layer, :rejected}] -> {:error, {:rejected, "target rejected the write"}}
      [{^layer, :transient}] -> {:error, {:transient, "target transiently unavailable"}}
      [{^layer, :forbidden}] -> {:error, %Ash.Error.Forbidden{}}
      [{^layer, :not_found}] -> {:error, %Ash.Error.Query.NotFound{}}
      _ -> delegate.()
    end
  end

  @doc """
  Arm the layer to run `fun.()` as a side effect right BEFORE its next
  `upsert`/`destroy` delegates — for deterministically reproducing "another
  write lands in the middle of this operation" races without real thread
  timing (M4: a write landing between `discard_local/1`'s local write and
  its chain destroy). Fires once, then disarms itself.
  """
  def run_before(layer, fun), do: :ets.insert(@table, {{layer, :before_write}, fun})

  @doc "Disarm the layer's before-write hook without it having fired."
  def clear_before(layer), do: :ets.delete(@table, {layer, :before_write})

  defp run_before_write(layer) do
    case :ets.lookup(@table, {layer, :before_write}) do
      [{_, fun}] ->
        :ets.delete(@table, {layer, :before_write})
        fun.()

      [] ->
        :ok
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

  @doc """
  Arm the layer's NEXT upsert to return `{:ok, {:upsert_skipped, query,
  callback}}` (M1: mirrors ash_sqlite/ash_postgres surfacing a
  condition-skipped upsert without a real `upsert_condition` fixture) —
  separate from `fail/2` so arming one never interferes with the other.
  """
  def skip_upsert(layer, query \\ nil, callback \\ fn -> {:ok, nil} end),
    do: :ets.insert(@table, {{layer, :upsert_skip}, {query, callback}})

  @doc "Disarm the layer's upsert-skip — upserts delegate/guard normally again."
  def clear_skip_upsert(layer), do: :ets.delete(@table, {layer, :upsert_skip})

  @doc false
  def guard_upsert(layer, delegate) do
    case :ets.lookup(@table, {layer, :upsert_skip}) do
      [{_, {query, callback}}] -> {:ok, {:upsert_skipped, query, callback}}
      [] -> guard(layer, delegate)
    end
  end
end
