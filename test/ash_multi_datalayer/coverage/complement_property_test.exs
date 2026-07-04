defmodule AshMultiDatalayer.Coverage.ComplementPropertyTest do
  @moduledoc """
  The completeness gate for remainder reads: over nil-heavy generated rows and
  the runtime evaluator every data layer uses, the coverage filter `C` and its
  complement `¬C` must **partition** the universe — every row matches exactly
  one. If any row matched neither, a remainder read would silently drop it (the
  three-valued-`NOT` hazard); if any matched both, it would be double-served.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AshMultiDatalayer.Coverage.{Complement, Normaliser}
  alias AshMultiDatalayer.Test.Generators
  alias AshMultiDatalayer.Test.Resources.TestPost

  property "C is faithful and C/¬C partition every row" do
    check all(
            filter <- Generators.filter(),
            rows <- list_of(Generators.row(), min_length: 1, max_length: 6),
            max_runs: 2000
          ) do
      normalised = Normaliser.normalise(filter, TestPost)

      unless normalised.opaque? do
        coverage = Complement.coverage_filter(normalised.disjuncts, TestPost)
        complement = Complement.complement_filter(normalised.disjuncts, TestPost)

        for row <- rows do
          in_coverage? = matches?(coverage, row)
          in_complement? = matches?(complement, row)
          row_view = Map.take(row, [:name, :age, :published_at])

          # (1) The coverage filter faithfully represents C.
          assert in_coverage? == truthy_match?(filter, row),
                 "coverage filter disagrees with #{inspect(filter)} on #{inspect(row_view)}"

          # (2) C and ¬C partition the universe — exactly one holds.
          assert in_coverage? != in_complement?,
                 "row #{inspect(row_view)} not partitioned by C = #{inspect(filter)}"
        end
      end
    end
  end

  defp matches?({:ok, filter}, row), do: truthy_match?(filter, row)
  defp matches?(:universe, _row), do: true
  defp matches?(:empty, _row), do: false

  defp truthy_match?(filter, row), do: Generators.matches?(row, filter) == {:ok, true}
end
