defmodule AshMultiDatalayer.Verifiers.ValidateAggregateOverrides do
  @moduledoc """
  Rejects aggregate override entries that don't name an aggregate on
  the resource — a typo would otherwise silently fold nothing (the real
  aggregate would join by default), so we catch it loudly at compile time.
  """
  use Spark.Dsl.Verifier

  alias AshMultiDatalayer.DataLayer.Info
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    # `sql_join_aggregate_overrides` is a ProvenCoverage concept; no-op for any
    # other strategy (orchestrator-behaviour ADR).
    if Info.proven_coverage?(dsl_state) do
      verify_overrides(dsl_state)
    else
      :ok
    end
  end

  defp verify_overrides(dsl_state) do
    aggregate_names =
      dsl_state
      |> Ash.Resource.Info.aggregates()
      |> MapSet.new(& &1.name)

    Enum.reduce_while(
      [:sql_join_aggregate_overrides, :fold_aggregate_overrides, :local_evaluation_overrides],
      :ok,
      fn option, :ok ->
        overrides = Verifier.get_option(dsl_state, [:multi_data_layer], option, [])

        case Enum.reject(overrides, &MapSet.member?(aggregate_names, &1)) do
          [] -> {:cont, :ok}
          unknown -> {:halt, unknown_override_error(dsl_state, option, unknown)}
        end
      end
    )
  end

  defp unknown_override_error(dsl_state, option, unknown) do
    {:error,
     Spark.Error.DslError.exception(
       module: Verifier.get_persisted(dsl_state, :module),
       path: [:multi_data_layer, option],
       message:
         "#{inspect(unknown)} in `#{option}` " <>
           "#{if length(unknown) == 1, do: "is not an aggregate", else: "are not aggregates"} " <>
           "on this resource. Only relationship aggregates can be overridden."
     )}
  end
end
