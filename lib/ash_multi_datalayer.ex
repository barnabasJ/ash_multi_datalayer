defmodule AshMultiDatalayer do
  @moduledoc """
  Generic ordered layered data layers for Ash resources.

  `ash_multi_datalayer` lets a resource route reads and writes across multiple
  underlying `Ash.DataLayer`s — most commonly an in-process ETS cache in front
  of a source of truth (Postgres, a remote Ash backend via `ash_remote`, …).

  See `AshMultiDatalayer.DataLayer` for the resource DSL, and the guides for
  layering recipes, operations, and telemetry.
  """
end
