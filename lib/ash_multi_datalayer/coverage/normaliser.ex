defmodule AshMultiDatalayer.Coverage.Normaliser do
  @moduledoc """
  Normalises an `Ash.Filter` to a disjunction of per-attribute intervals.

  The result is a `%Normalised{}` — a list of disjuncts, each a map of
  attribute name to `AshMultiDatalayer.Coverage.Interval`, plus an `opaque?`
  flag. Any shape outside the supported predicate set (simple attribute
  operators: `==`, `!=`, `in`, `<`, `<=`, `>`, `>=`, `is_nil`, combined with
  and/or/not) makes the whole filter opaque — opaque filters never subsume
  and are never subsumed. **Conservative on unknown is the correctness
  invariant**: incompleteness costs cache hits, never correctness.

  Within a disjunct, conjoined predicates on the same attribute are merged
  (`x > 1 and x < 5` → one range); unsatisfiable disjuncts are dropped
  (sound on both sides of an implication: `X or false ≡ X`). DNF expansion is
  capped at #{32} disjuncts; beyond that the filter is treated as opaque.
  """

  alias Ash.Query.{BooleanExpression, Not, Ref}
  alias AshMultiDatalayer.Coverage.Interval

  defmodule Normalised do
    @moduledoc """
    A filter in per-attribute interval DNF. `disjuncts` is a list of
    `%{attribute_name => Interval.t()}`; a row matches when it satisfies
    every interval of at least one disjunct.
    """
    defstruct disjuncts: [], opaque?: false

    @type t :: %__MODULE__{
            disjuncts: [%{atom() => AshMultiDatalayer.Coverage.Interval.t()}],
            opaque?: boolean()
          }
  end

  @max_disjuncts 32

  @operators %{
    Ash.Query.Operator.Eq => :eq,
    Ash.Query.Operator.NotEq => :not_eq,
    Ash.Query.Operator.In => :in,
    Ash.Query.Operator.LessThan => :lt,
    Ash.Query.Operator.LessThanOrEqual => :lte,
    Ash.Query.Operator.GreaterThan => :gt,
    Ash.Query.Operator.GreaterThanOrEqual => :gte,
    Ash.Query.Operator.IsNil => :is_nil
  }

  @doc """
  Normalises a filter (or expression) for `resource`. `nil`/`true` filters
  normalise to universal coverage (one unconstrained disjunct).
  """
  @spec normalise(Ash.Filter.t() | term(), Ash.Resource.t()) :: Normalised.t()
  def normalise(%Ash.Filter{expression: expression}, resource),
    do: normalise(expression, resource)

  def normalise(expression, resource) do
    case dnf(expression, resource) do
      :opaque -> %Normalised{disjuncts: [], opaque?: true}
      disjuncts -> %Normalised{disjuncts: disjuncts}
    end
  end

  @doc "Whether the expression is fully within the supported predicate set."
  @spec supported?(Ash.Filter.t() | term(), Ash.Resource.t()) :: boolean()
  def supported?(filter, resource), do: not normalise(filter, resource).opaque?

  # --- DNF construction ----------------------------------------------------
  #
  # Returns a list of disjuncts (maps of attr => Interval) or :opaque.
  #
  # `Not` is opaque except directly over `is_nil`. Ash's runtime match
  # semantics are not compositional over unknowns: a comparison with a nil
  # operand evaluates to nil, a bare `not` PROPAGATES that nil, but `or`
  # COLLAPSES it to false — so `not (x == v or ...)` can match a nil-x row
  # while any classically transformed form rejects it. `is_nil` is the only
  # predicate that always evaluates to a real boolean, making its negation
  # classical. (Both discovered by the property suite vs Ash.Filter.Runtime.)

  defp dnf(nil, _resource), do: [%{}]
  defp dnf(true, _resource), do: [%{}]
  defp dnf(false, _resource), do: []

  defp dnf(%Not{expression: %Ash.Query.Operator.IsNil{} = predicate}, resource) do
    predicate_disjuncts(predicate, true, resource)
  end

  defp dnf(%Not{}, _resource), do: :opaque

  defp dnf(%BooleanExpression{op: op, left: left, right: right}, resource) do
    with left_disjuncts when left_disjuncts != :opaque <- dnf(left, resource),
         right_disjuncts when right_disjuncts != :opaque <- dnf(right, resource) do
      case op do
        :or ->
          cap(left_disjuncts ++ right_disjuncts)

        :and ->
          product =
            for l <- left_disjuncts, r <- right_disjuncts do
              merge_disjuncts(l, r)
            end

          case Enum.member?(product, :opaque) do
            true -> :opaque
            false -> product |> Enum.reject(&(&1 == :unsatisfiable)) |> cap()
          end
      end
    else
      :opaque -> :opaque
    end
  end

  defp dnf(%struct{} = predicate, resource) when is_map_key(@operators, struct) do
    predicate_disjuncts(predicate, false, resource)
  end

  defp dnf(_other, _resource), do: :opaque

  defp predicate_disjuncts(predicate, negated?, resource) do
    case interval(predicate, negated?, resource) do
      :opaque -> :opaque
      :unsatisfiable -> []
      {attr, %Interval{} = interval} -> [%{attr => interval}]
    end
  end

  defp cap(disjuncts) do
    if length(disjuncts) > @max_disjuncts, do: :opaque, else: disjuncts
  end

  # --- predicate -> interval -------------------------------------------------

  defp interval(%struct{left: left, right: right}, negated?, resource) do
    op = Map.fetch!(@operators, struct)

    case {ref_attribute(left, resource), ref_attribute(right, resource)} do
      {{:ok, attr, type}, :not_a_ref} ->
        checked_interval(op, attr, type, right, negated?)

      {:not_a_ref, {:ok, attr, type}} ->
        case flip(op) do
          :opaque -> :opaque
          flipped -> checked_interval(flipped, attr, type, left, negated?)
        end

      _ ->
        :opaque
    end
  end

  # :is_nil takes a boolean (and is the only operator reachable with
  # negated?: true — see dnf/2); :in takes a list validated by
  # literal_list/1; every other operator requires a non-nil literal operand.
  defp checked_interval(:is_nil, attr, type, value, negated?),
    do: build_interval(:is_nil, attr, type, value, negated?)

  defp checked_interval(:in, attr, type, value, false),
    do: build_interval(:in, attr, type, value, false)

  defp checked_interval(op, attr, type, value, false) do
    if literal?(value) and not is_nil(value) do
      build_interval(op, attr, type, value, false)
    else
      :opaque
    end
  end

  defp checked_interval(_op, _attr, _type, _value, true), do: :opaque

  # A literal is anything that isn't a query AST node. Structs like Date,
  # Decimal, and DateTime are literals; refs, predicates, function calls, and
  # nested expressions are not.
  defp literal?(%{__predicate__?: _}), do: false
  defp literal?(%{__operator__?: _}), do: false
  defp literal?(%{__function__?: _}), do: false
  defp literal?(%Ref{}), do: false
  defp literal?(%Ash.Query.Call{}), do: false
  defp literal?(%Not{}), do: false
  defp literal?(%BooleanExpression{}), do: false
  defp literal?(_), do: true

  # `5 < x` is `x > 5`; equality and is_nil are symmetric.
  defp flip(:lt), do: :gt
  defp flip(:lte), do: :gte
  defp flip(:gt), do: :lt
  defp flip(:gte), do: :lte
  defp flip(:eq), do: :eq
  defp flip(:not_eq), do: :not_eq
  defp flip(_), do: :opaque

  defp ref_attribute(
         %Ref{relationship_path: [], attribute: %{name: name, type: type}},
         _resource
       ),
       do: {:ok, name, type}

  defp ref_attribute(%Ref{relationship_path: [], attribute: name}, resource)
       when is_atom(name) do
    case Ash.Resource.Info.attribute(resource, name) do
      %{name: name, type: type} -> {:ok, name, type}
      _ -> :opaque_ref
    end
  end

  defp ref_attribute(%Ref{}, _resource), do: :opaque_ref
  defp ref_attribute(_other, _resource), do: :not_a_ref

  defp build_interval(:is_nil, attr, type, right, negated?) do
    case right do
      value when is_boolean(value) ->
        nil? = value != negated?
        kind = if nil?, do: :is_nil, else: :not_nil
        {attr, %Interval{kind: kind, type: type}}

      _ ->
        :opaque
    end
  end

  defp build_interval(:eq, attr, type, value, false),
    do: {attr, %Interval{kind: :eq, type: type, values: [value]}}

  defp build_interval(:not_eq, attr, type, value, false),
    do: {attr, %Interval{kind: :not_eq, type: type, values: [value]}}

  defp build_interval(:in, attr, type, values, false) do
    case literal_list(values) do
      {:ok, []} -> :unsatisfiable
      {:ok, [value]} -> {attr, %Interval{kind: :eq, type: type, values: [value]}}
      {:ok, list} -> {attr, %Interval{kind: :in, type: type, values: list}}
      :error -> :opaque
    end
  end

  defp build_interval(:lt, attr, type, value, false),
    do: {attr, %Interval{kind: :range, type: type, lower: :unbounded, upper: {:excl, value}}}

  defp build_interval(:lte, attr, type, value, false),
    do: {attr, %Interval{kind: :range, type: type, lower: :unbounded, upper: {:incl, value}}}

  defp build_interval(:gt, attr, type, value, false),
    do: {attr, %Interval{kind: :range, type: type, lower: {:excl, value}, upper: :unbounded}}

  defp build_interval(:gte, attr, type, value, false),
    do: {attr, %Interval{kind: :range, type: type, lower: {:incl, value}, upper: :unbounded}}

  defp literal_list(%MapSet{} = values), do: literal_list(MapSet.to_list(values))

  defp literal_list(values) when is_list(values) do
    if Enum.all?(values, &(literal?(&1) and not is_nil(&1))) do
      {:ok, Enum.uniq(values)}
    else
      :error
    end
  end

  defp literal_list(_), do: :error

  # --- conjunction merge -----------------------------------------------------

  defp merge_disjuncts(left, right) do
    Enum.reduce_while(right, left, fn {attr, interval}, acc ->
      case Map.fetch(acc, attr) do
        :error ->
          {:cont, Map.put(acc, attr, interval)}

        {:ok, existing} ->
          case merge_intervals(existing, interval) do
            :unsatisfiable -> {:halt, :unsatisfiable}
            :opaque -> {:halt, :opaque}
            merged -> {:cont, Map.put(acc, attr, merged)}
          end
      end
    end)
  end

  @doc false
  # Conjunction of two intervals on the same attribute. Returns a merged
  # Interval, :unsatisfiable (the disjunct can never match), or :opaque.
  def merge_intervals(%Interval{type: t1}, %Interval{type: t2}) when t1 != t2, do: :opaque

  def merge_intervals(%Interval{kind: :is_nil} = interval, %Interval{kind: :is_nil}),
    do: interval

  # All comparison kinds are nil-rejecting, so combined with :is_nil they
  # can never both hold; combined with :not_nil they absorb it.
  def merge_intervals(%Interval{kind: :is_nil}, %Interval{}), do: :unsatisfiable
  def merge_intervals(%Interval{}, %Interval{kind: :is_nil}), do: :unsatisfiable
  def merge_intervals(%Interval{kind: :not_nil}, %Interval{} = other), do: other
  def merge_intervals(%Interval{} = interval, %Interval{kind: :not_nil}), do: interval

  def merge_intervals(%Interval{kind: :eq, values: [v]} = eq, other) do
    case Interval.contains_value?(other, v) do
      true -> eq
      false -> :unsatisfiable
      :error -> :opaque
    end
  end

  def merge_intervals(other, %Interval{kind: :eq} = eq), do: merge_intervals(eq, other)

  def merge_intervals(%Interval{kind: :in, values: values} = interval, other) do
    values
    |> Enum.reduce_while([], fn v, acc ->
      case Interval.contains_value?(other, v) do
        true -> {:cont, [v | acc]}
        false -> {:cont, acc}
        :error -> {:halt, :opaque}
      end
    end)
    |> case do
      :opaque -> :opaque
      [] -> :unsatisfiable
      [value] -> %Interval{kind: :eq, type: interval.type, values: [value]}
      values -> %Interval{interval | values: Enum.reverse(values)}
    end
  end

  def merge_intervals(other, %Interval{kind: :in} = interval),
    do: merge_intervals(interval, other)

  def merge_intervals(%Interval{kind: :range} = left, %Interval{kind: :range} = right) do
    with {:ok, lower} <- tighter_lower(left.lower, right.lower),
         {:ok, upper} <- tighter_upper(left.upper, right.upper) do
      merged = %Interval{kind: :range, type: left.type, lower: lower, upper: upper}

      if satisfiable_range?(merged), do: merged, else: :unsatisfiable
    else
      :error -> :opaque
    end
  end

  # not_eq combined with ranges/other not_eq has no single-interval
  # representation (except the trivial equal case); stay narrow.
  def merge_intervals(
        %Interval{kind: :not_eq, values: [v1]} = interval,
        %Interval{kind: :not_eq, values: [v2]}
      ) do
    case Interval.compare(v1, v2) do
      :eq -> interval
      :error -> :opaque
      _ -> :opaque
    end
  end

  def merge_intervals(%Interval{}, %Interval{}), do: :opaque

  defp tighter_lower(:unbounded, bound), do: {:ok, bound}
  defp tighter_lower(bound, :unbounded), do: {:ok, bound}

  defp tighter_lower({k1, v1} = left, {k2, v2} = right) do
    case Interval.compare(v1, v2) do
      :gt -> {:ok, left}
      :lt -> {:ok, right}
      :eq -> {:ok, if(k1 == :excl or k2 == :excl, do: {:excl, v1}, else: {:incl, v1})}
      :error -> :error
    end
  end

  defp tighter_upper(:unbounded, bound), do: {:ok, bound}
  defp tighter_upper(bound, :unbounded), do: {:ok, bound}

  defp tighter_upper({k1, v1} = left, {k2, v2} = right) do
    case Interval.compare(v1, v2) do
      :lt -> {:ok, left}
      :gt -> {:ok, right}
      :eq -> {:ok, if(k1 == :excl or k2 == :excl, do: {:excl, v1}, else: {:incl, v1})}
      :error -> :error
    end
  end

  defp satisfiable_range?(%Interval{lower: :unbounded}), do: true
  defp satisfiable_range?(%Interval{upper: :unbounded}), do: true

  defp satisfiable_range?(%Interval{lower: {lk, lv}, upper: {uk, uv}}) do
    case Interval.compare(lv, uv) do
      :lt -> true
      :eq -> lk == :incl and uk == :incl
      _ -> false
    end
  end
end
