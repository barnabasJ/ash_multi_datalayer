defmodule AshMultiDatalayer.Orchestrator.LocalOutbox.Flush do
  @moduledoc """
  The body of the outbox `:flush` action (library code, so fixes ship in the
  library rather than in generated user files). Invoked by the ash_oban-generated
  worker with the entry's `primary_key`.

  **Phase 3 scope:** the per-PK **chain-head check** on `seq` — the correctness
  spine of ordered draining. If a lower-`seq` pending/parked entry exists for the
  same `(resource, record_pk, target)`, this entry is not the chain head and the
  job completes without flushing (the head's completion re-triggers).

  **Phase 4 completes it:** the actual push to `target` via `Backfill`, the
  offline/transient/rejection/conflict triage (snooze / retry / self-park —
  ash_oban's `on_error` does not fire for generic-action triggers), success
  deletion + chain-continuation kick, and `conflict_detection`.
  """
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  @impl true
  def run(input, _opts, context) do
    outbox = input.resource
    domain = context.domain
    seq = pk_seq(input.arguments.primary_key)

    case Ash.get(outbox, %{seq: seq}, domain: domain, authorize?: false) do
      {:error, _} ->
        # The entry is gone (already flushed/discarded). Nothing to do.
        {:ok, :entry_missing}

      {:ok, entry} ->
        if chain_head?(outbox, domain, entry) do
          # Phase 4: push `entry.payload`/destroy to `entry.target` via Backfill,
          # triage the result, delete on success + kick the next chain entry.
          {:ok, {:chain_head, entry.seq}}
        else
          {:ok, :not_chain_head}
        end
    end
  end

  @doc false
  # No pending/parked entry with the same (resource, record_pk, target) and a
  # lower seq — i.e. this entry is the head of its per-PK chain.
  def chain_head?(outbox, domain, entry) do
    outbox
    |> Ash.Query.for_read(
      :for_record,
      %{resource: entry.resource, record_pk: entry.record_pk, target: entry.target},
      domain: domain,
      authorize?: false
    )
    |> Ash.Query.filter(seq < ^entry.seq)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> Enum.empty?()
  end

  defp pk_seq(pk) when is_map(pk), do: pk["seq"] || pk[:seq]
end
