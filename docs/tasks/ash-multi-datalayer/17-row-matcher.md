# Task 17: `Coverage.Invalidation.should_drop?/3` via `Ash.Filter.Runtime`

**Phase**: 7 — Row-aware invalidation **Depends on**: 14 **Blocks**: 18, 19
**Size**: M

## Objective

Implement row-aware ledger invalidation: given a ledger entry's filter and a
row's before/after attribute values, decide whether the entry should be dropped.
Use `Ash.Filter.Runtime.do_match/2` (the same evaluator primary datalayers use
on reads).

## Out of Scope

- The property test suite (Task 18).
- Integration with the write path (Task 19).
- Handling of opaque/unsupported predicates beyond the conservative drop policy.

## Context

Per
[ADR 20260417-row-aware-invalidation](../../design/20260417-row-aware-invalidation-adr.md),
drop-all-on-write makes the ledger churn faster than it can warm. Row-aware
invalidation drops only entries whose filter matches the changed row.

## Detailed Steps

### 1. Module shape

```elixir
defmodule AshMultiDatalayer.Coverage.Invalidation do
  @moduledoc """
  Row-aware ledger invalidation.

  Given a ledger entry's filter and the before/after state of a
  changed row, decide whether the entry should be dropped.
  """

  alias AshMultiDatalayer.Coverage.Entry

  @doc """
  `row_before` and `row_after` are attribute maps; either may be `nil`
  (for create: `row_before == nil`; for destroy: `row_after == nil`).
  """
  @spec should_drop?(Entry.t(), map() | nil, map() | nil) :: boolean()
  def should_drop?(%Entry{filter: filter}, row_before, row_after) do
    matches_before = evaluate_or_unknown(filter, row_before)
    matches_after = evaluate_or_unknown(filter, row_after)

    case {matches_before, matches_after} do
      {:unknown, _} -> true
      {_, :unknown} -> true
      {true, _} -> true
      {_, true} -> true
      _ -> false
    end
  end
end
```

### 2. Evaluator wrapper

```elixir
defp evaluate_or_unknown(_filter, nil), do: false

defp evaluate_or_unknown(filter, row) do
  case Ash.Filter.Runtime.do_match(row, filter) do
    {:ok, true} -> true
    {:ok, false} -> false
    {:error, _reason} -> :unknown
    :unknown -> :unknown
  end
end
```

Exact return-shape of `do_match/2` depends on the Ash version pinned — confirm
against `Ash.Filter.Runtime` source during implementation. Map any
non-`true`/`false` result to `:unknown`.

### 3. Mass invalidation

```elixir
@doc """
Drop all ledger entries that match the changed row, for the given
resource+tenant. Returns the count dropped.
"""
@spec on_write(module(), term(), atom(), map() | nil, map() | nil) :: non_neg_integer()
def on_write(resource, tenant, _operation, row_before, row_after) do
  entries = AshMultiDatalayer.Coverage.entries(resource, tenant)

  entries
  |> Enum.filter(&should_drop?(&1, row_before, row_after))
  |> tap(fn to_drop ->
    Enum.each(to_drop, fn entry ->
      AshMultiDatalayer.Coverage.drop(resource, tenant, entry.id)
    end)
  end)
  |> length()
end
```

### 4. Telemetry emission

After `on_write/5`, emit:

```elixir
:telemetry.execute(
  [:ash_multi_datalayer, :ledger, :invalidated],
  %{count: dropped_count},
  %{resource: resource, tenant: tenant}
)
```

## Files to Create/Modify

- `lib/ash_multi_datalayer/coverage/invalidation.ex` — new.
- `test/ash_multi_datalayer/coverage/invalidation_test.exs` — new; unit tests
  for each case.

## Patterns to Follow

- `Ash.Filter.Runtime.do_match/2` — existing runtime evaluator. Do not
  reimplement filter evaluation.

## Acceptance Criteria

- [ ] `should_drop?/3` returns `true` when the filter matches `row_before`.
- [ ] Returns `true` when the filter matches `row_after`.
- [ ] Returns `true` when either evaluation is `:unknown`.
- [ ] Returns `false` when the filter matches neither side.
- [ ] `nil` rows treated as non-matching (not `:unknown`).
- [ ] `on_write/5` drops matching entries and keeps non-matching ones.
- [ ] Emits `:invalidated` telemetry with the correct count.

## Definition of Done

- [ ] Code compiles with no warnings
- [ ] Tests pass (new + existing)
- [ ] `mix dialyzer` clean
- [ ] Acceptance criteria verified

## Verification

```bash
cd /home/joba/sandbox/ash_multi_datalayer
mix test test/ash_multi_datalayer/coverage/invalidation_test.exs
mix dialyzer
```

## Notes

- **Conservative on unknown** is the correctness invariant — same principle as
  the subsumption solver. Over-invalidation costs cache hit rate;
  under-invalidation costs correctness.
- Do NOT cache `Ash.Filter.Runtime` results across calls; rows change per call.
- `row_before` and `row_after` are **attribute maps**, not Ash records — prepare
  them from the changeset's `data`/`attributes` in Task 19.
