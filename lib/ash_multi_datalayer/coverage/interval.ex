defmodule AshMultiDatalayer.Coverage.Interval do
  @moduledoc """
  A per-attribute constraint in normalised (DNF) filter form.

  Kinds:

    * `:eq` — exactly one value (`values: [v]`)
    * `:in` — one of several values (`values: [...]`, non-empty)
    * `:range` — ordered interval with `lower`/`upper` bounds, each
      `{:incl, v} | {:excl, v} | :unbounded`
    * `:not_eq` — anything but one value (`values: [v]`, non-nil rows only)
    * `:is_nil` — the attribute is nil
    * `:not_nil` — the attribute is non-nil

  `type` carries the attribute's `Ash.Type` for defence-in-depth: containment
  across differing types is always `false`.

  All comparison kinds (`:eq`, `:in`, `:range`, `:not_eq`) match only non-nil
  values, mirroring Ash's nil-rejecting operator semantics.
  """

  defstruct [:kind, :type, :lower, :upper, values: []]

  @type bound :: {:incl, term()} | {:excl, term()} | :unbounded
  @type t :: %__MODULE__{
          kind: :eq | :in | :range | :not_eq | :is_nil | :not_nil,
          type: term(),
          lower: bound() | nil,
          upper: bound() | nil,
          values: [term()]
        }

  @doc "Safe three-way comparison. `:error` when the values aren't comparable."
  @spec compare(term(), term()) :: :lt | :eq | :gt | :error
  def compare(left, right) do
    case Comp.compare(left, right) do
      result when result in [:lt, :eq, :gt] -> result
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  @doc "Safe equality via the same comparison semantics the runtime uses."
  @spec equal?(term(), term()) :: boolean()
  def equal?(left, right), do: compare(left, right) == :eq

  @doc """
  Whether a concrete (non-nil) value satisfies the interval. `:error` when
  a comparison is impossible — callers must treat that conservatively.
  """
  @spec contains_value?(t(), term()) :: boolean() | :error
  def contains_value?(%__MODULE__{kind: :eq, values: [v]}, value) do
    case compare(value, v) do
      :eq -> true
      :error -> :error
      _ -> false
    end
  end

  def contains_value?(%__MODULE__{kind: :not_eq, values: [v]}, value) do
    case compare(value, v) do
      :eq -> false
      :error -> :error
      _ -> true
    end
  end

  def contains_value?(%__MODULE__{kind: :in, values: values}, value) do
    Enum.reduce_while(values, false, fn v, acc ->
      case compare(value, v) do
        :eq -> {:halt, true}
        :error -> {:halt, :error}
        _ -> {:cont, acc}
      end
    end)
  end

  def contains_value?(%__MODULE__{kind: :range} = interval, value) do
    with above when is_boolean(above) <- above_lower?(interval.lower, value),
         below when is_boolean(below) <- below_upper?(interval.upper, value) do
      above and below
    end
  end

  def contains_value?(%__MODULE__{kind: :not_nil}, _value), do: true
  def contains_value?(%__MODULE__{kind: :is_nil}, _value), do: false

  defp above_lower?(:unbounded, _value), do: true

  defp above_lower?({:incl, bound}, value) do
    case compare(value, bound) do
      :lt -> false
      :error -> :error
      _ -> true
    end
  end

  defp above_lower?({:excl, bound}, value) do
    case compare(value, bound) do
      :gt -> true
      :error -> :error
      _ -> false
    end
  end

  defp below_upper?(:unbounded, _value), do: true

  defp below_upper?({:incl, bound}, value) do
    case compare(value, bound) do
      :gt -> false
      :error -> :error
      _ -> true
    end
  end

  defp below_upper?({:excl, bound}, value) do
    case compare(value, bound) do
      :lt -> true
      :error -> :error
      _ -> false
    end
  end

  @doc """
  Whether every value in `inner` is contained in `outer` (`inner ⊆ outer`).

  Conservative: `false` on any type mismatch, comparison failure, or pair of
  kinds without a proven containment rule.
  """
  @spec subset?(t(), t()) :: boolean()
  def subset?(%__MODULE__{type: t1}, %__MODULE__{type: t2}) when t1 != t2, do: false

  # Everything a comparison interval matches is non-nil.
  def subset?(%__MODULE__{kind: kind}, %__MODULE__{kind: :not_nil})
      when kind in [:eq, :in, :range, :not_eq, :not_nil],
      do: true

  def subset?(%__MODULE__{kind: :is_nil}, %__MODULE__{kind: :is_nil}), do: true

  def subset?(%__MODULE__{kind: :eq, values: [v]}, outer) do
    contains_value?(outer, v) == true
  end

  def subset?(%__MODULE__{kind: :in, values: values}, outer) do
    Enum.all?(values, &(contains_value?(outer, &1) == true))
  end

  # L4: string/CiString range bounds are byte-ordered here (`Comp.compare/2`),
  # but the source of truth compares under its own (typically ICU/locale)
  # collation — `name > "B"` does NOT reliably subsume `name > "b"` there
  # (case ordering differs from ASCII byte order), so a coverage hit could
  # silently drop rows the source would actually return. Refuse subsumption
  # for these types unless both bounds are identical (byte-order-independent:
  # the same range is always the same range under any collation).
  def subset?(
        %__MODULE__{kind: :range, type: type} = inner,
        %__MODULE__{kind: :range, type: type} = outer
      )
      when type in [Ash.Type.String, Ash.Type.CiString] do
    inner.lower == outer.lower and inner.upper == outer.upper
  end

  def subset?(%__MODULE__{kind: :range} = inner, %__MODULE__{kind: :range} = outer) do
    lower_within?(outer.lower, inner.lower) and upper_within?(outer.upper, inner.upper)
  end

  def subset?(%__MODULE__{kind: :not_eq, values: [v1]}, %__MODULE__{kind: :not_eq, values: [v2]}) do
    equal?(v1, v2)
  end

  def subset?(%__MODULE__{}, %__MODULE__{}), do: false

  # outer.lower must be at or below inner.lower
  defp lower_within?(:unbounded, _inner), do: true
  defp lower_within?(_outer, :unbounded), do: false

  defp lower_within?({outer_kind, outer_bound}, {inner_kind, inner_bound}) do
    case compare(outer_bound, inner_bound) do
      :lt -> true
      :eq -> outer_kind == :incl or inner_kind == :excl
      :gt -> false
      :error -> false
    end
  end

  # outer.upper must be at or above inner.upper
  defp upper_within?(:unbounded, _inner), do: true
  defp upper_within?(_outer, :unbounded), do: false

  defp upper_within?({outer_kind, outer_bound}, {inner_kind, inner_bound}) do
    case compare(outer_bound, inner_bound) do
      :gt -> true
      :eq -> outer_kind == :incl or inner_kind == :excl
      :lt -> false
      :error -> false
    end
  end
end
