defmodule AshMultiDatalayer.Sync.Changes.DefaultTransientExhausted do
  @moduledoc false
  # On the ash_oban `on_error` path, `:park` runs with no input, so default
  # `error_class` to `:transient_exhausted`. An explicit `error_class` (a
  # rejection/conflict park) is left untouched.
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :error_class) do
      nil -> Ash.Changeset.force_change_attribute(changeset, :error_class, :transient_exhausted)
      _ -> changeset
    end
  end
end
