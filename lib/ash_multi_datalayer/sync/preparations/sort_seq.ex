defmodule AshMultiDatalayer.Sync.Preparations.SortSeq do
  @moduledoc false
  # Applies the injected read action's default sort (built as a preparation so it
  # can be constructed from a transformer, which cannot use the `prepare build/1`
  # DSL macro).
  use Ash.Resource.Preparation

  @impl true
  def prepare(query, opts, _context) do
    case opts[:sort] do
      nil -> query
      sort -> Ash.Query.sort(query, sort)
    end
  end
end
