defmodule AshMultiDatalayer.Verifiers.ValidateMultitenancy do
  @moduledoc """
  A multitenant resource needs every declared layer to support multitenancy —
  the ledger partitions coverage by tenant, but the layers themselves must
  isolate the data.
  """
  use Spark.Dsl.Verifier

  alias AshMultiDatalayer.DataLayer.Info
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    case Ash.Resource.Info.multitenancy_strategy(dsl_state) do
      nil ->
        :ok

      strategy ->
        dsl_state
        |> Info.layers()
        |> Enum.reject(&layer_can?(&1.module, dsl_state, :multitenancy))
        |> case do
          [] ->
            :ok

          [%{name: name, module: module} | _] ->
            {:error,
             Spark.Error.DslError.exception(
               module: Verifier.get_persisted(dsl_state, :module),
               path: [:multi_data_layer],
               message:
                 "this resource uses #{inspect(strategy)} multitenancy, but layer " <>
                   "#{inspect(name)} (#{inspect(module)}) does not support multitenancy"
             )}
        end
    end
  end

  defp layer_can?(module, dsl_state, feature) do
    module.can?(dsl_state, feature)
  rescue
    _ -> false
  end
end
