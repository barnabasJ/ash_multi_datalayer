defmodule AshMultiDatalayer.Coverage.ImplicationTest do
  use ExUnit.Case, async: true

  alias AshMultiDatalayer.Coverage.{Implication, Normaliser}
  alias AshMultiDatalayer.Test.Resources.TestPost

  defp n(statement) do
    TestPost
    |> Ash.Filter.parse!(statement)
    |> Normaliser.normalise(TestPost)
  end

  defp implies?(a, b), do: Implication.implies?(n(a), n(b))

  describe "reflexivity and simple containment" do
    test "every supported filter implies itself" do
      for statement <- [
            [name: [eq: "foo"]],
            [age: [greater_than: 18]],
            [name: [in: ~w(a b)]],
            [age: [is_nil: true]],
            [or: [[name: [eq: "a"]], [age: [less_than: 5]]]]
          ] do
        normalised = n(statement)
        refute normalised.opaque?

        assert Implication.implies?(normalised, normalised),
               "not reflexive: #{inspect(statement)}"
      end
    end

    test "narrower eq implies broader eq/in/range/not_eq/universal" do
      assert implies?([name: [eq: "a"]], name: [eq: "a"])
      refute implies?([name: [eq: "a"]], name: [eq: "b"])
      assert implies?([name: [eq: "a"]], name: [in: ~w(a b)])
      refute implies?([name: [eq: "c"]], name: [in: ~w(a b)])
      assert implies?([age: [eq: 20]], age: [greater_than: 18])
      refute implies?([age: [eq: 10]], age: [greater_than: 18])
      assert implies?([name: [eq: "a"]], name: [not_eq: "b"])
      refute implies?([name: [eq: "a"]], name: [not_eq: "a"])
      assert implies?([name: [eq: "a"]], nil)
    end

    test "conjunction is narrower than either conjunct" do
      assert implies?([name: [eq: "foo"], age: [greater_than: 18]], name: [eq: "foo"])
      assert implies?([name: [eq: "foo"], age: [greater_than: 18]], age: [greater_than: 18])
      refute implies?([name: [eq: "foo"]], name: [eq: "foo"], age: [greater_than: 18])
    end

    test "range containment respects inclusive/exclusive bounds" do
      assert implies?([age: [greater_than: 5, less_than: 10]], age: [greater_than: 5])
      assert implies?([age: [greater_than_or_equal: 6]], age: [greater_than: 5])
      refute implies?([age: [greater_than_or_equal: 5]], age: [greater_than: 5])
      assert implies?([age: [greater_than: 5]], age: [greater_than_or_equal: 5])
      assert implies?([age: [less_than: 5]], age: [less_than_or_equal: 5])
      refute implies?([age: [less_than_or_equal: 5]], age: [less_than: 5])
    end

    test "in-set containment" do
      assert implies?([name: [in: ~w(a b)]], name: [in: ~w(a b c)])
      refute implies?([name: [in: ~w(a d)]], name: [in: ~w(a b c)])
      assert implies?([name: [in: ~w(a)]], name: [eq: "a"])
    end

    test "is_nil only implied by is_nil; comparisons imply not-nil" do
      assert implies?([age: [is_nil: true]], age: [is_nil: true])
      refute implies?([age: [is_nil: true]], age: [greater_than: 0])
      refute implies?([age: [greater_than: 0]], age: [is_nil: true])
      assert implies?([age: [greater_than: 0]], age: [is_nil: false])
      assert implies?([age: [eq: 3]], age: [is_nil: false])
      assert implies?([age: [not_eq: 3]], age: [is_nil: false])
    end
  end

  describe "disjunctions" do
    test "a disjunction implies b iff every disjunct implies b" do
      a = [or: [[name: [eq: "a"]], [name: [eq: "b"]]]]
      assert implies?(a, name: [in: ~w(a b c)])
      refute implies?(a, name: [eq: "a"])
    end

    test "a filter implies a disjunction when contained in one branch" do
      b = [or: [[name: [eq: "a"]], [age: [greater_than: 100]]]]
      assert implies?([name: [eq: "a"]], b)
      assert implies?([name: [eq: "a"], age: [eq: 5]], b)
      refute implies?([age: [eq: 5]], b)
    end

    test "cross-branch splits are not proven (conservative)" do
      a = [or: [[age: [eq: 1]], [age: [eq: 3]]]]
      b = [age: [in: [1, 3]]]

      # Each a-disjunct fits inside b's single disjunct: proven.
      assert implies?(a, b)

      # The reverse is logically true but requires splitting b's single
      # disjunct across two a-branches — the documented completeness gap of
      # interval containment ("SAT would say yes, we say no"). Costs a cache
      # hit, never correctness.
      refute implies?(b, a)
    end
  end

  describe "soundness of the attribute union rule" do
    test "an RHS-only attribute constraint fails containment" do
      # {name: foo} must NOT imply {name: foo, age > 18} — the task-12
      # pseudocode iterating only LHS attributes got this wrong.
      refute implies?([name: [eq: "foo"]], name: [eq: "foo"], age: [greater_than: 18])
    end
  end

  describe "conservative cases" do
    test "opaque filters never imply and are never implied" do
      # Relationship path predicates are unsupported.
      opaque = Ash.Filter.parse!(TestPost, name: [contains: "a"])
      normalised = Normaliser.normalise(opaque, TestPost)
      assert normalised.opaque?

      supported = n(name: [eq: "a"])
      refute Implication.implies?(normalised, supported)
      refute Implication.implies?(supported, normalised)
      refute Implication.implies?(normalised, normalised)
    end

    test "type mismatch across attributes is false" do
      # Same value, different attribute types: age vs name never contain
      # each other even with overlapping shapes.
      refute implies?([age: [eq: 1]], name: [eq: "1"])
    end
  end

  describe "normalisation details" do
    test "unsatisfiable disjuncts are dropped" do
      normalised = n(name: [eq: "a"], age: [eq: 1, not_eq: 1])
      assert normalised.disjuncts == []
      refute normalised.opaque?
    end

    test "conjoined ranges merge into one interval" do
      normalised = n(age: [greater_than: 1, less_than: 5])

      assert [%{age: %{kind: :range, lower: {:excl, 1}, upper: {:excl, 5}}}] =
               normalised.disjuncts
    end

    test "only is_nil has a sound negation" do
      # not(is_nil) -> not_nil: is_nil always evaluates to a real boolean.
      assert implies?([not: [age: [is_nil: true]]], age: [is_nil: false])
      assert implies?([not: [age: [is_nil: false]]], age: [is_nil: true])
    end

    test "negated comparisons are opaque (a nil operand makes `not` match)" do
      # `not (x == v)` MATCHES x-is-nil rows at runtime, while the classical
      # dual `x != v` rejects them — so no negated comparison is normalised.
      for statement <- [
            [not: [age: [less_than: 5]]],
            [not: [name: [eq: "a"]]],
            [not: [name: [not_eq: "a"]]],
            [not: [name: [in: ~w(a b)]]]
          ] do
        assert n(statement).opaque?, "expected opaque: #{inspect(statement)}"
      end
    end

    test "the DNF disjunct cap makes wide filters opaque" do
      wide =
        Enum.reduce(1..40, [name: [eq: "x"]], fn i, acc ->
          [or: [acc, [age: [eq: rem(i, 6)]]]]
        end)

      assert n(wide).opaque?
    end
  end
end
