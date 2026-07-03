defmodule AshMultiDatalayer.Verifiers.RejectFieldPolicies do
  @moduledoc """
  Rejects `field_policies` combined with a multi-layer `read_order`.

  Field policies redact per actor at the action boundary, but cache-served
  rows were materialised under a *different* request's actor — the solver
  cannot prove field-level policy compatibility across actors, so serving
  them would bypass redaction. Single-layer `read_order` is always accepted
  (no fall-through, policies apply normally). See ADR
  20260417-reject-field-policies-with-fallthrough.
  """
  use Spark.Dsl.Verifier

  alias AshMultiDatalayer.DataLayer.Info
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    if field_policies?(dsl_state) and length(Info.read_order(dsl_state)) > 1 do
      {:error,
       Spark.Error.DslError.exception(
         module: Verifier.get_persisted(dsl_state, :module),
         path: [:field_policies],
         message: """
         field_policies cannot be combined with a multi-layer read_order:
         cache-served rows would bypass per-actor field redaction.

         Either remove the field_policies, or disable fall-through reads by
         setting read_order to just the source of truth, e.g.:

             read_order [#{inspect(List.last(Info.read_order(dsl_state)))}]

         See ADR 20260417-reject-field-policies-with-fallthrough.
         """
       )}
    else
      :ok
    end
  end

  defp field_policies?(dsl_state) do
    Ash.Policy.Info.field_policies(dsl_state) != []
  rescue
    _ -> false
  end
end
