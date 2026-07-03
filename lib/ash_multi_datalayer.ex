defmodule AshMultiDatalayer do
  @moduledoc """
  Generic ordered layered data layers for Ash resources.

  `ash_multi_datalayer` lets a resource route reads and writes across multiple
  underlying `Ash.DataLayer`s — most commonly an in-process ETS cache in front
  of a source of truth (Postgres, a remote Ash backend via `ash_remote`, …).

  See `AshMultiDatalayer.DataLayer` for the resource DSL, and the guides for
  layering recipes, operations, and telemetry.
  """

  @doc """
  Disables layered behaviour for a resource at runtime: reads route to the
  last layer in `read_order`, writes to the first layer in `write_order`
  (both the source of truth), skipping cache layers and coverage entirely.
  """
  defdelegate disable!(resource), to: AshMultiDatalayer.KillSwitch

  @doc "Re-enables layered behaviour for a resource. See `disable!/1`."
  defdelegate enable!(resource), to: AshMultiDatalayer.KillSwitch

  @doc "Whether layered behaviour is currently enabled for the resource."
  defdelegate enabled?(resource), to: AshMultiDatalayer.KillSwitch
end
