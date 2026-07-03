defmodule AshMultiDatalayer.Coverage.Entry do
  @moduledoc """
  One coverage-ledger record: a filter whose full result set has been
  materialised into the earlier read layers for a tenant.

  Stores both forms of the filter: the raw `Ash.Filter` (row-aware
  invalidation re-evaluates it against changed rows via
  `Ash.Filter.Runtime`) and the normalised interval DNF (the implication
  solver decides subsumption on it without re-normalising per read).
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
          loaded_at: integer()
        }
end
