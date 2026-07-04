defmodule AshMultiDatalayer.Verifiers.ValidateAggregateOverrides do
  @moduledoc """
  Rejects `sql_join_aggregate_overrides` entries that don't name an aggregate on
  the resource — a typo would otherwise silently fold nothing (the real
  aggregate would join by default), so we catch it loudly at compile time.
  """
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    overrides =
      Verifier.get_option(dsl_state, [:multi_data_layer], :sql_join_aggregate_overrides, [])

    aggregate_names =
      dsl_state
      |> Ash.Resource.Info.aggregates()
      |> MapSet.new(& &1.name)

    case Enum.reject(overrides, &MapSet.member?(aggregate_names, &1)) do
      [] ->
        :ok

      unknown ->
        {:error,
         Spark.Error.DslError.exception(
           module: Verifier.get_persisted(dsl_state, :module),
           path: [:multi_data_layer, :sql_join_aggregate_overrides],
           message:
             "#{inspect(unknown)} in `sql_join_aggregate_overrides` " <>
               "#{if length(unknown) == 1, do: "is not an aggregate", else: "are not aggregates"} " <>
               "on this resource. Only relationship aggregates can be overridden to fold."
         )}
    end
  end
end
