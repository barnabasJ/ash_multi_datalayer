defmodule AshMultiDatalayer.Test.Generators do
  @moduledoc """
  StreamData generators for the solver/invalidation property suites.

  Filters and rows are drawn from a small finite domain over `TestPost`'s
  attributes so that generated filter pairs frequently overlap — the
  interesting cases for subsumption and invalidation.
  """

  import StreamData

  alias AshMultiDatalayer.Test.Resources.TestPost

  @names ~w(a b c d e)
  @ages [0, 1, 2, 3, 5, 10]
  @dates [~D[2026-01-01], ~D[2026-03-15], ~D[2026-06-30], ~D[2026-12-31]]

  @doc "A parsed `%Ash.Filter{}` over TestPost's finite attribute domain."
  def filter do
    statement()
    |> map(&Ash.Filter.parse!(TestPost, &1))
  end

  @doc "A TestPost row (struct) with values from the same domain, nils included."
  def row do
    fixed_map(%{
      name: one_of([constant(nil), member_of(@names)]),
      age: one_of([constant(nil), member_of(@ages)]),
      published_at: one_of([constant(nil), member_of(@dates)])
    })
    |> map(&struct(TestPost, &1))
  end

  @doc "A filter statement (the keyword form `Ash.Filter.parse!/2` accepts)."
  def statement do
    tree(leaf(), fn child ->
      one_of([
        bind({child, child}, fn {l, r} -> constant(and: [l, r]) end),
        bind({child, child}, fn {l, r} -> constant(or: [l, r]) end),
        bind(child, fn c -> constant(not: c) end)
      ])
    end)
  end

  defp leaf do
    one_of([name_predicate(), age_predicate(), date_predicate()])
  end

  defp name_predicate do
    one_of([
      member_of(@names) |> map(&[name: [eq: &1]]),
      member_of(@names) |> map(&[name: [not_eq: &1]]),
      list_of(member_of(@names), min_length: 1, max_length: 3)
      |> map(&[name: [in: Enum.uniq(&1)]]),
      boolean() |> map(&[name: [is_nil: &1]])
    ])
  end

  defp age_predicate do
    one_of([
      member_of(@ages) |> map(&[age: [eq: &1]]),
      member_of(@ages) |> map(&[age: [not_eq: &1]]),
      list_of(member_of(@ages), min_length: 1, max_length: 3)
      |> map(&[age: [in: Enum.uniq(&1)]]),
      member_of(@ages) |> map(&[age: [less_than: &1]]),
      member_of(@ages) |> map(&[age: [less_than_or_equal: &1]]),
      member_of(@ages) |> map(&[age: [greater_than: &1]]),
      member_of(@ages) |> map(&[age: [greater_than_or_equal: &1]]),
      boolean() |> map(&[age: [is_nil: &1]])
    ])
  end

  defp date_predicate do
    one_of([
      member_of(@dates) |> map(&[published_at: [eq: &1]]),
      member_of(@dates) |> map(&[published_at: [less_than: &1]]),
      member_of(@dates) |> map(&[published_at: [greater_than_or_equal: &1]]),
      boolean() |> map(&[published_at: [is_nil: &1]])
    ])
  end

  @doc """
  Ground-truth row matching via the same runtime evaluator the data layers
  use. `{:ok, boolean}` or `:unknown`.
  """
  def matches?(row, %Ash.Filter{} = filter) do
    # Ash keeps records on TRUTHY results, not `== true` — mirror that.
    case Ash.Filter.Runtime.do_match(row, filter) do
      {:ok, falsy} when falsy in [false, nil] -> {:ok, false}
      {:ok, _truthy} -> {:ok, true}
      :unknown -> :unknown
      {:error, _} -> :unknown
    end
  end
end
