defmodule AshMultiDatalayer.Orchestrator.LocalOutbox.ConflictError do
  @moduledoc """
  Raised/returned when a `write_through` write's inline chain-drain
  (`drain_chain_inline/2`) hits a stale-check conflict: an in-flight entry for
  the same record was rejected by the target because the target's row has
  diverged from the entry's recorded `base_image`. Carries the target's
  current snapshot so the caller sees a typed Ash error (the same
  `remote_snapshot` a normal async flush parks with) instead of an opaque
  `{:conflict, remote}` tuple.
  """
  use Splode.Error, fields: [:remote_snapshot], class: :invalid

  def message(%__MODULE__{remote_snapshot: remote_snapshot}) do
    "write_through could not drain an in-flight entry: the target's row has diverged " <>
      "(remote snapshot: #{inspect(remote_snapshot)}). Resolve the conflict (e.g. via " <>
      "rebase/2 on the parked entry) before retrying this write."
  end
end
