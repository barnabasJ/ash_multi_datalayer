defmodule AshMultiDatalayer.Debug do
  @moduledoc """
  Read-only introspection helpers for operating the library — safe to run in
  production `iex` sessions.
  """

  alias AshMultiDatalayer.Coverage
  alias AshMultiDatalayer.Coverage.{Implication, Normaliser}
  alias AshMultiDatalayer.DataLayer.Query

  @doc """
  All coverage-ledger entries for a resource (optionally scoped to a
  tenant; `nil` is the tenantless partition). No side effects.
  """
  @spec dump_ledger(module(), term()) :: [Coverage.Entry.t()]
  def dump_ledger(resource, tenant \\ nil) do
    Coverage.entries(resource, tenant)
  end

  @doc """
  Explains the coverage decision for a query: returns
  `{decision, per_entry_trace}` where decision is `{:hit, entry}` or
  `{:miss, reason}` and the trace lists every ledger entry with why it did
  or didn't cover the query (`:covers`, `:not_implied`,
  `:fields_insufficient`).

  Accepts an `Ash.Query` (uses its filter/select/tenant).
  """
  @spec explain_covers?(module(), Ash.Query.t()) :: {term(), [map()]}
  def explain_covers?(resource, %Ash.Query{} = ash_query) do
    query = %Query{
      resource: resource,
      filter: ash_query.filter,
      select: ash_query.select,
      tenant: ash_query.tenant
    }

    probe = Normaliser.normalise(query.filter, resource)
    needed_fields = Coverage.needed_fields(query, resource)
    entries = Coverage.entries(resource, query.tenant)

    trace =
      Enum.map(entries, fn entry ->
        implied? = not probe.opaque? and Implication.implies?(probe, entry.normalised)
        fields? = MapSet.subset?(needed_fields, entry.loaded_fields)

        verdict =
          cond do
            probe.opaque? -> :solver_unsupported
            implied? and fields? -> :covers
            implied? -> :fields_insufficient
            true -> :not_implied
          end

        %{
          entry: entry,
          filter: entry.filter && inspect(entry.filter),
          verdict: verdict,
          loaded_fields: MapSet.to_list(entry.loaded_fields)
        }
      end)

    decision =
      cond do
        probe.opaque? ->
          {:miss, :solver_unsupported}

        entry_trace = Enum.find(trace, &(&1.verdict == :covers)) ->
          {:hit, entry_trace.entry}

        Enum.any?(trace, &(&1.verdict == :fields_insufficient)) ->
          {:miss, :fields_insufficient}

        true ->
          {:miss, :no_coverage_entry}
      end

    {decision, trace}
  end
end
