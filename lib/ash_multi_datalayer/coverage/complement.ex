defmodule AshMultiDatalayer.Coverage.Complement do
  @moduledoc """
  Builds, from a coverage region `C` in normalised interval-DNF form, two Ash
  filters used for remainder reads:

    * `coverage_filter/2` — a filter matching `C` (the covered region).
    * `complement_filter/2` — a filter matching **`¬C`**, the exact, nil-safe
      set-complement of `C`.

  The complement is the delicate one. In SQL/Ash three-valued logic a bare
  `not (a > 5)` is *not* the set-complement of `a > 5` — a row with `a = nil`
  satisfies neither, so it would be dropped by both the cache (`C`) and a naive
  remainder, silently vanishing. So every leaf is complemented in **positive
  form with an explicit `is_nil` escape hatch**: `¬(a > 5)` becomes
  `a <= 5 or is_nil(a)`. No three-valued `NOT` ever reaches the wire.

  Per leaf this is the exact set-complement (`{comparison false} ∪ {a is nil}`);
  De Morgan composes exact complements exactly, so `C ∨ ¬C` is the universe and
  `(Q ∧ C) ∪ (Q ∧ ¬C) = Q` for any `Q`. The completeness property suite is the
  gate on that claim.

  Both filters are produced as Ash filter statements and parsed against the
  resource, so values round-trip through the resource's attribute types.
  """

  alias AshMultiDatalayer.Coverage.Interval

  @typedoc "A DNF: list of disjuncts, each a map of attribute name to interval."
  @type disjuncts :: [%{atom() => Interval.t()}]

  @typedoc """
  A filter region: an explicit filter, or the degenerate whole-universe / empty
  regions (for which no predicate need be sent).
  """
  @type region :: {:ok, Ash.Filter.t()} | :universe | :empty

  @doc """
  A filter matching the coverage region `disjuncts` (`C`).

  Returns `{:ok, filter}`, or `:universe` when the region is unconstrained
  (matches every row — `C` already covers everything), or `:empty` when the
  region matches nothing.
  """
  @spec coverage_filter(disjuncts(), Ash.Resource.t()) ::
          {:ok, Ash.Filter.t()} | :universe | :empty
  def coverage_filter([], _resource), do: :empty

  def coverage_filter(disjuncts, resource) do
    cond do
      Enum.any?(disjuncts, &(&1 == %{})) -> :universe
      true -> {:ok, Ash.Filter.parse!(resource, or_stmt(Enum.map(disjuncts, &disjunct_stmt/1)))}
    end
  end

  @doc """
  A filter matching the nil-safe complement `¬C` of the coverage region.

  Returns `{:ok, filter}`, or `:universe` when `C` is empty (its complement is
  everything), or `:empty` when `C` is unconstrained (its complement matches
  nothing).
  """
  @spec complement_filter(disjuncts(), Ash.Resource.t()) ::
          {:ok, Ash.Filter.t()} | :universe | :empty
  def complement_filter([], _resource), do: :universe

  def complement_filter(disjuncts, resource) do
    cond do
      Enum.any?(disjuncts, &(&1 == %{})) ->
        :empty

      true ->
        # ¬(D₁ ∨ … ∨ Dₙ) = ¬D₁ ∧ … ∧ ¬Dₙ
        {:ok,
         Ash.Filter.parse!(resource, and_stmt(Enum.map(disjuncts, &complement_disjunct_stmt/1)))}
    end
  end

  # --- coverage (positive) statements ---------------------------------------

  # A disjunct is a conjunction of per-attribute intervals.
  defp disjunct_stmt(disjunct) when disjunct == %{}, do: true

  defp disjunct_stmt(disjunct),
    do: and_stmt(Enum.map(disjunct, fn {attr, interval} -> interval_stmt(attr, interval) end))

  defp interval_stmt(attr, %Interval{kind: :eq, values: [v]}), do: %{attr => [eq: v]}
  defp interval_stmt(attr, %Interval{kind: :not_eq, values: [v]}), do: %{attr => [not_eq: v]}
  defp interval_stmt(attr, %Interval{kind: :in, values: vs}), do: %{attr => [in: vs]}
  defp interval_stmt(attr, %Interval{kind: :is_nil}), do: %{attr => [is_nil: true]}
  defp interval_stmt(attr, %Interval{kind: :not_nil}), do: %{attr => [is_nil: false]}

  defp interval_stmt(attr, %Interval{kind: :range, lower: lower, upper: upper}) do
    and_stmt(Enum.reject([lower_stmt(attr, lower), upper_stmt(attr, upper)], &(&1 == true)))
  end

  defp lower_stmt(_attr, :unbounded), do: true
  defp lower_stmt(attr, {:incl, v}), do: %{attr => [greater_than_or_equal: v]}
  defp lower_stmt(attr, {:excl, v}), do: %{attr => [greater_than: v]}

  defp upper_stmt(_attr, :unbounded), do: true
  defp upper_stmt(attr, {:incl, v}), do: %{attr => [less_than_or_equal: v]}
  defp upper_stmt(attr, {:excl, v}), do: %{attr => [less_than: v]}

  # --- complement (nil-safe) statements -------------------------------------

  # ¬D = ¬(interval₁ ∧ … ∧ intervalₖ) = ¬interval₁ ∨ … ∨ ¬intervalₖ
  defp complement_disjunct_stmt(disjunct),
    do:
      or_stmt(
        Enum.map(disjunct, fn {attr, interval} -> complement_interval_stmt(attr, interval) end)
      )

  # Each leaf's exact set-complement: the negated comparison OR the attribute
  # is nil. `:is_nil`/`:not_nil` are two-valued, so their complement is plain.
  defp complement_interval_stmt(attr, %Interval{kind: :eq, values: [v]}),
    do: or_nil(attr, %{attr => [not_eq: v]})

  defp complement_interval_stmt(attr, %Interval{kind: :not_eq, values: [v]}),
    do: or_nil(attr, %{attr => [eq: v]})

  defp complement_interval_stmt(attr, %Interval{kind: :in, values: vs}),
    do: or_nil(attr, and_stmt(Enum.map(vs, &%{attr => [not_eq: &1]})))

  defp complement_interval_stmt(attr, %Interval{kind: :is_nil}), do: %{attr => [is_nil: false]}
  defp complement_interval_stmt(attr, %Interval{kind: :not_nil}), do: %{attr => [is_nil: true]}

  defp complement_interval_stmt(attr, %Interval{kind: :range, lower: lower, upper: upper}) do
    below = complement_lower_stmt(attr, lower)
    above = complement_upper_stmt(attr, upper)
    or_stmt(Enum.reject([below, above, %{attr => [is_nil: true]}], &is_nil/1))
  end

  # "not above the lower bound": `a > 5` (excl) → `a <= 5`; `a >= 5` (incl) → `a < 5`.
  defp complement_lower_stmt(_attr, :unbounded), do: nil
  defp complement_lower_stmt(attr, {:incl, v}), do: %{attr => [less_than: v]}
  defp complement_lower_stmt(attr, {:excl, v}), do: %{attr => [less_than_or_equal: v]}

  # "not below the upper bound": `a < 5` (excl) → `a >= 5`; `a <= 5` (incl) → `a > 5`.
  defp complement_upper_stmt(_attr, :unbounded), do: nil
  defp complement_upper_stmt(attr, {:incl, v}), do: %{attr => [greater_than: v]}
  defp complement_upper_stmt(attr, {:excl, v}), do: %{attr => [greater_than_or_equal: v]}

  # --- statement helpers ----------------------------------------------------

  defp or_nil(attr, stmt), do: or_stmt([stmt, %{attr => [is_nil: true]}])

  defp and_stmt([]), do: true
  defp and_stmt([single]), do: single
  defp and_stmt(list), do: [and: list]

  defp or_stmt([]), do: false
  defp or_stmt([single]), do: single
  defp or_stmt(list), do: [or: list]
end
