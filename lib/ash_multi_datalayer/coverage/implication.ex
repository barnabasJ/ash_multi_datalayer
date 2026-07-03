defmodule AshMultiDatalayer.Coverage.Implication do
  @moduledoc """
  Filter-subsumption solver for the coverage ledger.

  Decides `implies?(a, b)` — whether every row matching `a` necessarily
  matches `b` — by set containment over normalised per-attribute interval
  DNF (see `AshMultiDatalayer.Coverage.Normaliser`). The coverage check calls
  `implies?(probe, cached)`: the incoming query must be provably narrower
  than (or equal to) a recorded filter for the cache to serve it.

  Conservative on uncertainty: opaque filters, type mismatches, and interval
  pairs without a proven containment rule are all `false`. A wrong `true`
  here serves stale rows — the worst failure mode — so completeness is
  always sacrificed for soundness.
  """

  alias AshMultiDatalayer.Coverage.Interval
  alias AshMultiDatalayer.Coverage.Normaliser.Normalised

  @doc """
  `true` iff `a` logically implies `b` (every `a`-row is a `b`-row).

  A disjunction implies `b` only when every disjunct does; a disjunct is
  implied when at least one of `b`'s disjuncts contains it on **every**
  attribute either side constrains — an attribute constrained only by the
  `b` side means `b` is narrower there, so containment fails.
  """
  @spec implies?(Normalised.t(), Normalised.t()) :: boolean()
  def implies?(%Normalised{opaque?: true}, _b), do: false
  def implies?(_a, %Normalised{opaque?: true}), do: false

  def implies?(%Normalised{disjuncts: a_disjuncts}, %Normalised{disjuncts: b_disjuncts}) do
    Enum.all?(a_disjuncts, fn a_disjunct ->
      Enum.any?(b_disjuncts, &disjunct_subset?(a_disjunct, &1))
    end)
  end

  # Every attribute constrained by either side must prove containment.
  # Iterating only one side is unsound: {name: "foo"} must NOT be judged a
  # subset of {name: "foo", age: >18}.
  defp disjunct_subset?(a_disjunct, b_disjunct) do
    a_disjunct
    |> Map.keys()
    |> Enum.concat(Map.keys(b_disjunct))
    |> Enum.uniq()
    |> Enum.all?(fn attr ->
      case {Map.fetch(a_disjunct, attr), Map.fetch(b_disjunct, attr)} do
        # b doesn't constrain this attribute: anything a does is narrower.
        {{:ok, _a_interval}, :error} -> true
        # b constrains it, a doesn't: a admits values b rejects.
        {:error, {:ok, _b_interval}} -> false
        {{:ok, a_interval}, {:ok, b_interval}} -> Interval.subset?(a_interval, b_interval)
      end
    end)
  end
end
