defmodule AshMultiDatalayer.Coverage.Entry do
  @moduledoc """
  One coverage-ledger record: a filter whose full result set has been
  materialised into the earlier read layers for a tenant.

  Stores both forms of the filter: the raw `Ash.Filter` (row-aware
  invalidation re-evaluates it against changed rows via
  `Ash.Filter.Runtime`) and the normalised interval DNF (the implication
  solver decides subsumption on it without re-normalising per read).

  `loaded_at` is wall-clock (`DateTime.utc_now/0`), not
  `System.monotonic_time/0` — a persisted coverage store (see
  `AshMultiDatalayer.Coverage.Store`) restores entries across a BEAM restart,
  and only a wall-clock timestamp survives that round-trip meaningfully; a
  monotonic value from a prior incarnation is not comparable to one drawn in
  the current incarnation. Compare with `DateTime.compare/2` (or pass
  `DateTime` as an `Enum.min_by/4` sorter) — the default term-order `<` does
  NOT sort `%DateTime{}` chronologically (its struct fields compare
  alphabetically, e.g. `day` before `month`/`year`).
  """

  defstruct [
    :id,
    :tenant,
    :filter,
    :normalised,
    :fingerprint,
    :loaded_fields,
    :loaded_at
  ]

  @type t :: %__MODULE__{
          id: reference(),
          tenant: term(),
          filter: Ash.Filter.t() | nil,
          normalised: AshMultiDatalayer.Coverage.Normaliser.Normalised.t(),
          fingerprint: term(),
          loaded_fields: MapSet.t(atom()),
          loaded_at: DateTime.t()
        }
end
