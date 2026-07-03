defmodule AshMultiDatalayer.Coverage.InvalidationPropertyTest do
  @moduledoc """
  Property: `should_drop?/3` equals "the filter matches (or is unknown on)
  the before-row or the after-row", with `Ash.Filter.Runtime` as ground
  truth. Under-dropping is a staleness bug; over-dropping only costs hit
  rate — so the assertion is exact equality against match-or-unknown.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :property
  @moduletag timeout: 300_000

  alias AshMultiDatalayer.Coverage.{Entry, Invalidation, Normaliser}
  alias AshMultiDatalayer.Test.Generators
  alias AshMultiDatalayer.Test.Resources.TestPost

  property "should_drop? == matches_or_unknown(before) or matches_or_unknown(after)" do
    check all(
            filter <- Generators.filter(),
            row_before <- StreamData.one_of([StreamData.constant(nil), Generators.row()]),
            row_after <- StreamData.one_of([StreamData.constant(nil), Generators.row()]),
            max_runs: 10_000
          ) do
      entry = %Entry{
        id: make_ref(),
        tenant: :__global__,
        filter: filter,
        normalised: Normaliser.normalise(filter, TestPost),
        loaded_fields: MapSet.new([:id]),
        loaded_at: 0
      }

      expected = matches_or_unknown?(filter, row_before) or matches_or_unknown?(filter, row_after)

      assert Invalidation.should_drop?(entry, row_before, row_after) == expected
    end
  end

  defp matches_or_unknown?(_filter, nil), do: false

  defp matches_or_unknown?(filter, row) do
    case Generators.matches?(row, filter) do
      {:ok, result} -> result
      :unknown -> true
    end
  end
end
