defmodule AshMultiDatalayer.KillSwitch do
  @moduledoc """
  Per-resource runtime kill-switch backed by `:persistent_term`.

  When a resource is disabled, reads route only to the last layer in
  `read_order` and writes only to the first layer in `write_order` — both the
  source of truth — skipping the cache layers and coverage lookups entirely.
  Ledger invalidation still runs on writes while disabled, so re-enabling
  cannot serve coverage that predates the disabled window.

  The check is a single `:persistent_term.get/2` — lock-free, safe on every
  operation. `enable!/1` erases the key rather than storing `:enabled`, so
  the persistent-term table doesn't accumulate entries.
  """

  @spec enabled?(module()) :: boolean()
  def enabled?(resource) do
    :persistent_term.get(key(resource), :enabled) == :enabled
  end

  @spec disable!(module()) :: :ok
  def disable!(resource) do
    :persistent_term.put(key(resource), :disabled)
  end

  @spec enable!(module()) :: :ok
  def enable!(resource) do
    :persistent_term.erase(key(resource))
    :ok
  end

  defp key(resource), do: {:ash_multi_datalayer, resource}
end
