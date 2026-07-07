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

  # `local_evaluation_overrides` holds CALCULATION names (data_layer.ex's doc:
  # "Calculation names…"; consumed at value_merge.ex:57 as
  # `calculation.name not in overrides`) — a different vocabulary from the
  # other two options, which hold aggregate names.
  defp verify_overrides(dsl_state) do
    aggregate_names = dsl_state |> Ash.Resource.Info.aggregates() |> MapSet.new(& &1.name)
    calculation_names = dsl_state |> Ash.Resource.Info.calculations() |> MapSet.new(& &1.name)

    Enum.reduce_while(
      [
        {:sql_join_aggregate_overrides, aggregate_names, :aggregate},
        {:fold_aggregate_overrides, aggregate_names, :aggregate},
        {:local_evaluation_overrides, calculation_names, :calculation}
      ],
      :ok,
      fn {option, known_names, kind}, :ok ->
        overrides = Verifier.get_option(dsl_state, [:multi_data_layer], option, [])

        case Enum.reject(overrides, &MapSet.member?(known_names, &1)) do
          [] -> {:cont, :ok}
          unknown -> {:halt, unknown_override_error(dsl_state, option, unknown, kind)}
        end
      end
    )
  end

  defp unknown_override_error(dsl_state, option, unknown, :aggregate) do
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

  defp unknown_override_error(dsl_state, option, unknown, :calculation) do
    {:error,
     Spark.Error.DslError.exception(
       module: Verifier.get_persisted(dsl_state, :module),
       path: [:multi_data_layer, option],
       message:
         "#{inspect(unknown)} in `#{option}` " <>
           "#{if length(unknown) == 1, do: "is not a calculation", else: "are not calculations"} " <>
           "on this resource."
     )}
  end
end
