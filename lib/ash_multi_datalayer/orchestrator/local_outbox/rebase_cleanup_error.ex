defmodule AshMultiDatalayer.Orchestrator.LocalOutbox.RebaseCleanupError do
  @moduledoc """
  `rebase/2`'s resolution changeset applied successfully, but cleanup of the
  OLD parked chain failed. Nothing was destroyed (the cleanup runs inside one
  outbox-repo transaction) — the resolution is durably applied locally and its
  fresh entries exist, but sit `:blocked` behind the still-parked head named
  here. No divergence, no lost evidence, just paused replication (visible via
  `parked/2`). Recovery: `discard/1` (or `retry/1`, once the underlying cause
  is fixed) on the named head.
  """
  defexception [:cause, :resource, :record_pk, :target, :head_seq]

  @impl true
  def message(%__MODULE__{
        cause: cause,
        resource: resource,
        record_pk: record_pk,
        target: target,
        head_seq: head_seq
      }) do
    "rebase/2 applied its resolution write, but cleanup of the old parked chain failed: " <>
      "#{Exception.format(:error, cause)}. The resolution is applied locally; its fresh " <>
      "entries are held :blocked behind the still-parked head (resource: #{resource}, " <>
      "record_pk: #{inspect(record_pk)}, target: #{inspect(target)}, entry seq: " <>
      "#{inspect(head_seq)}) — resolve it via discard/1 (or retry/1, once the cause is fixed) " <>
      "to unblock the chain."
  end
end
