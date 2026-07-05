defmodule AshMultiDatalayer.Verifiers.ValidateOrchestrator do
  @moduledoc """
  Validates the configured `orchestrator`:

    * the module implements the `AshMultiDatalayer.Orchestrator` behaviour
      (all required callbacks are present);
    * the module's own `validate_opts/2` (if defined) accepts the configured
      opts.

  Applies to every strategy — it is the one verifier that is never strategy-
  gated, since it is what proves the strategy is a valid orchestrator at all.
  """
  use Spark.Dsl.Verifier

  alias AshMultiDatalayer.DataLayer.Info
  alias Spark.Dsl.Verifier

  # The non-optional callbacks of `AshMultiDatalayer.Orchestrator`.
  @required_callbacks [
    read: 2,
    create: 2,
    update: 2,
    upsert: 4,
    destroy: 2,
    authority: 1,
    transaction_layer: 1,
    can?: 2
  ]

  @impl true
  def verify(dsl_state) do
    {module, opts} = Info.orchestrator(dsl_state)
    resource = Verifier.get_persisted(dsl_state, :module)

    with :ok <- ensure_implements_behaviour(module, resource, dsl_state) do
      validate_opts(module, dsl_state, opts, resource)
    end
  end

  defp ensure_implements_behaviour(module, resource, dsl_state) do
    case Code.ensure_compiled(module) do
      {:module, ^module} ->
        missing =
          Enum.reject(@required_callbacks, fn {fun, arity} ->
            function_exported?(module, fun, arity)
          end)

        if missing == [] do
          :ok
        else
          error(
            resource,
            dsl_state,
            "#{inspect(module)} is configured as the `orchestrator` but does not implement " <>
              "the AshMultiDatalayer.Orchestrator behaviour — missing callbacks: " <>
              "#{inspect(missing)}."
          )
        end

      {:error, reason} ->
        error(
          resource,
          dsl_state,
          "the configured `orchestrator` #{inspect(module)} could not be compiled/loaded " <>
            "(#{inspect(reason)})."
        )
    end
  end

  defp validate_opts(module, dsl_state, opts, resource) do
    if function_exported?(module, :validate_opts, 2) do
      case module.validate_opts(dsl_state, opts) do
        :ok -> :ok
        {:error, message} when is_binary(message) -> error(resource, dsl_state, message)
      end
    else
      :ok
    end
  end

  defp error(resource, dsl_state, message) do
    {:error,
     Spark.Error.DslError.exception(
       module: resource || Verifier.get_persisted(dsl_state, :module),
       path: [:multi_data_layer, :orchestrator],
       message: message
     )}
  end
end
