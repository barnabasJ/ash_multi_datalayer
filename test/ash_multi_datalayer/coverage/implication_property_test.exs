defmodule AshMultiDatalayer.Coverage.ImplicationPropertyTest do
  @moduledoc """
  Property suite for the solver, cross-checked against `Ash.Filter.Runtime`
  (the exact evaluator the data layers use at read time).

  Two properties:

    1. **Normalisation equivalence** — for a non-opaque filter, evaluating
       the interval DNF against a row agrees with the runtime evaluator
       whenever the runtime's verdict is known. This pins the normaliser in
       both directions (no false positives *or* negatives).

    2. **Implication soundness** — whenever `implies?(a, b)` is true, every
       row the runtime says matches `a` must match `b`. A violation here is
       a stale-read bug, the worst failure mode of the library.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :property
  @moduletag timeout: 300_000

  alias AshMultiDatalayer.Coverage.{Implication, Interval, Normaliser}
  alias AshMultiDatalayer.Test.Generators
  alias AshMultiDatalayer.Test.Resources.TestPost

  @runs 10_000

  property "normalised DNF evaluation agrees with Ash.Filter.Runtime" do
    check all(
            filter <- Generators.filter(),
            rows <- StreamData.list_of(Generators.row(), length: 5),
            max_runs: @runs
          ) do
      normalised = Normaliser.normalise(filter, TestPost)

      unless normalised.opaque? do
        for row <- rows do
          case Generators.matches?(row, filter) do
            {:ok, expected} ->
              assert eval(normalised, row) == expected,
                     "normalised evaluation disagrees with runtime for " <>
                       "#{inspect(filter)} on #{inspect(Map.take(row, [:name, :age, :published_at]))}"

            :unknown ->
              :ok
          end
        end
      end
    end
  end

  property "implies?(a, b) is sound: every a-row is a b-row" do
    check all(
            filter_a <- Generators.filter(),
            filter_b <- Generators.filter(),
            rows <- StreamData.list_of(Generators.row(), length: 5),
            max_runs: @runs
          ) do
      normalised_a = Normaliser.normalise(filter_a, TestPost)
      normalised_b = Normaliser.normalise(filter_b, TestPost)

      if Implication.implies?(normalised_a, normalised_b) do
        for row <- rows do
          with {:ok, true} <- Generators.matches?(row, filter_a),
               {:ok, matches_b} <- Generators.matches?(row, filter_b) do
            assert matches_b,
                   "UNSOUND: implies? claimed #{inspect(filter_a)} => #{inspect(filter_b)} " <>
                     "but row #{inspect(Map.take(row, [:name, :age, :published_at]))} " <>
                     "matches a and not b"
          else
            _ -> :ok
          end
        end
      end
    end
  end

  property "implies? is reflexive on supported filters" do
    check all(filter <- Generators.filter(), max_runs: 1_000) do
      normalised = Normaliser.normalise(filter, TestPost)

      unless normalised.opaque? do
        assert Implication.implies?(normalised, normalised)
      end
    end
  end

  # Reference evaluation of the interval DNF against a row.
  defp eval(%{disjuncts: disjuncts}, row) do
    Enum.any?(disjuncts, fn disjunct ->
      Enum.all?(disjunct, fn {attr, interval} ->
        value = Map.get(row, attr)
        interval_matches?(interval, value)
      end)
    end)
  end

  defp interval_matches?(%Interval{kind: :is_nil}, value), do: is_nil(value)
  defp interval_matches?(%Interval{kind: :not_nil}, value), do: not is_nil(value)
  defp interval_matches?(%Interval{}, nil), do: false

  defp interval_matches?(interval, value) do
    Interval.contains_value?(interval, value) == true
  end
end
