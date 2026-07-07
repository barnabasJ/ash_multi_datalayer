defmodule AshMultiDatalayer.Sync.Enqueue do
  @moduledoc """
  MDL owns its Oban touchpoints: **one enqueue helper, five call sites** — the
  immediate kick on the write path, the chain continuation in the flush success
  path, the retry re-trigger, the `resume_sync/1` backlog kick, and the
  `kick_next` after `force/1`/`rebase/2`.

  ash_oban 0.8.10 hardcodes the default `Oban` instance on every enqueue path
  (`run_trigger/3`, `schedule/3`, and the generated workers all call bare
  `Oban.insert!/1`), so it cannot target a named instance. This helper builds the
  job against ash_oban's generated flush worker and inserts it via
  `Oban.insert(instance, job)` itself — keeping telemetry and unique-job args
  uniform across all sites even in single-instance deployments, and never
  stalling a chain in a multi-instance deployment (Phase 2 item 11).

  The instance is resolved from the `outbox_entry` config by default; worker-side
  call sites pass `instance:` explicitly (from `job.conf.name`), caller-side
  sites from the same process-scoped establishment as the dynamic repo.
  """

  @doc """
  Insert a flush job for `entry` (an outbox entry record) into the configured
  Oban instance. Options: `:instance` overrides the resolved instance (worker-side
  sites pass `job.conf.name`).
  """
  @spec flush(Ash.Resource.t(), Ash.Resource.record(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def flush(outbox_resource, entry, opts \\ []) do
    instance = opts[:instance] || AshMultiDatalayer.Sync.Info.oban_instance(outbox_resource)
    worker = flush_worker(outbox_resource)
    args = %{"primary_key" => %{"seq" => entry.seq}, "write_ref" => entry.write_ref}

    Oban.insert(instance, worker.new(args))
  end

  @doc """
  `flush/3`, but for the post-commit "best effort" kick sites that
  historically discarded the result outright (P6/#4): a lost kick must not
  vanish silently. The row (already durably committed) stays `:pending`
  regardless of whether this succeeds — `AshMultiDatalayer.Orchestrator.
  LocalOutbox.Sweeper` recovers it on its next tick either way, so this
  only makes an immediate failure visible instead of invisible.
  """
  @spec flush_and_log(Ash.Resource.t(), Ash.Resource.record(), keyword()) :: :ok
  def flush_and_log(outbox_resource, entry, opts \\ []) do
    case flush(outbox_resource, entry, opts) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        require Logger

        Logger.warning(
          "ash_multi_datalayer: failed to enqueue a LocalOutbox flush job for " <>
            "#{entry.resource} (seq #{entry.seq}): #{inspect(reason)} — the entry stays " <>
            "pending and will be recovered by the outbox sweeper"
        )

        :ok
    end
  end

  @doc "The ash_oban-generated worker module backing the outbox `:flush` trigger."
  @spec flush_worker(Ash.Resource.t()) :: module()
  def flush_worker(outbox_resource) do
    outbox_resource
    |> AshOban.Info.oban_triggers()
    |> Enum.find(&(&1.name == :flush))
    |> case do
      nil -> raise ArgumentError, "#{inspect(outbox_resource)} has no :flush trigger"
      trigger -> trigger.worker
    end
  end
end
