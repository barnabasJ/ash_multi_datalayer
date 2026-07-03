defmodule AshMultiDatalayer.Verifiers.ValidateSolverSupportedPredicates do
  @moduledoc """
  Warns when the resource's statically-known filters fall outside the
  subsumption solver's supported predicate set — such reads always fall
  through to the source of truth and are never cached.

  Best-effort: only the resource `base_filter` can be checked at compile
  time (per-query filters are runtime values). Unsupported shapes are not an
  error — they cost hit rate, never correctness.
  """
  use Spark.Dsl.Verifier

  alias AshMultiDatalayer.Coverage.Normaliser
  alias AshMultiDatalayer.DataLayer.Info
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    with true <- length(Info.read_order(dsl_state)) > 1,
         base_filter when not is_nil(base_filter) <-
           Ash.Resource.Info.base_filter(dsl_state),
         module when not is_nil(module) <- Verifier.get_persisted(dsl_state, :module),
         {:ok, filter} <- parse(module, base_filter),
         false <- Normaliser.supported?(filter, module) do
      {:warn,
       "the base_filter of #{inspect(module)} is outside the subsumption " <>
         "solver's supported predicate set (==, !=, in, <, <=, >, >=, " <>
         "is_nil, and/or/not-is_nil). Every read will fall through to the " <>
         "source of truth without caching."}
    else
      _ -> :ok
    end
  end

  defp parse(module, base_filter) do
    {:ok, Ash.Filter.parse!(module, base_filter)}
  rescue
    # The resource is still compiling; parsing may be impossible. Skip.
    _ -> :skip
  end
end
