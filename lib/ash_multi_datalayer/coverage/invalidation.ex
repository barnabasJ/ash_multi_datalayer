defmodule AshMultiDatalayer.Coverage.Invalidation do
  @moduledoc """
  Row-aware coverage invalidation.

  After a successful authoritative write, every ledger entry whose filter
  matches the changed row — in its before **or** after state — is dropped;
  unrelated entries survive, preserving cache hit rate under write load.
  Matching uses `Ash.Filter.Runtime.do_match/6`, the same evaluator data
  layers use at read time, with `unknown_on_unknown_refs?: true` so any
  unresolvable reference drops the entry conservatively.

  This runs **before** the written record is propagated into earlier layers
  (FR3.6): if that propagation then fails, the covering entries are already
  gone, so the failure degrades to a coverage miss — never a stale read.
  """

  alias AshMultiDatalayer.Coverage
  alias AshMultiDatalayer.Coverage.Entry
  alias AshMultiDatalayer.Telemetry

  @doc """
  Whether a ledger entry must be dropped for a row change.

  `row_before`/`row_after` are records (or `nil`: creates have no before,
  destroys no after). Conservative: an `:unknown` evaluation on either side
  drops the entry. Entries with no filter (universal coverage) match every
  row.
  """
  @spec should_drop?(Entry.t(), Ash.Resource.record() | nil, Ash.Resource.record() | nil) ::
          boolean()
  def should_drop?(%Entry{filter: nil}, row_before, row_after) do
    not (is_nil(row_before) and is_nil(row_after))
  end

  def should_drop?(%Entry{filter: filter}, row_before, row_after) do
    matches_or_unknown?(filter, row_before) or matches_or_unknown?(filter, row_after)
  end

  defp matches_or_unknown?(_filter, nil), do: false

  defp matches_or_unknown?(filter, row) do
    # Ash keeps records on TRUTHY results, not `== true` — mirror that.
    case Ash.Filter.Runtime.do_match(row, filter, nil, nil, true) do
      {:ok, falsy} when falsy in [false, nil] -> false
      {:ok, _truthy} -> true
      :unknown -> true
      {:error, _} -> true
    end
  rescue
    # An evaluator crash counts as unknown: drop conservatively.
    _ -> true
  end

  @doc """
  Drops every ledger entry (for the resource+tenant) matching the changed
  row, emitting `[:ash_multi_datalayer, :ledger, :invalidated]` with the
  dropped count. Returns the count.
  """
  @spec on_write(module(), term(), Ash.Resource.record() | nil, Ash.Resource.record() | nil) ::
          non_neg_integer()
  def on_write(resource, tenant, row_before, row_after) do
    dropped =
      resource
      |> Coverage.entries(tenant)
      |> Enum.filter(&should_drop?(&1, row_before, row_after))

    Enum.each(dropped, &Coverage.drop(resource, tenant, &1.id))

    count = length(dropped)

    if count > 0 do
      Telemetry.ledger(:invalidated, resource, tenant, %{
        count: count,
        ledger_size: Coverage.size(resource, tenant)
      })
    end

    count
  end

  @doc """
  Drops **all** ledger entries for the resource+tenant. Used for writes with
  no reliable before-image (upserts): without knowing the previous row
  state, only clearing the partition is provably safe.
  """
  @spec drop_all(module(), term()) :: non_neg_integer()
  def drop_all(resource, tenant) do
    entries = Coverage.entries(resource, tenant)
    Enum.each(entries, &Coverage.drop(resource, tenant, &1.id))

    count = length(entries)

    if count > 0 do
      Telemetry.ledger(:invalidated, resource, tenant, %{count: count, ledger_size: 0})
    end

    count
  end
end
