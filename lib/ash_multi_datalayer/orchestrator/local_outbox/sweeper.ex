defmodule AshMultiDatalayer.Orchestrator.LocalOutbox.Sweeper do
  @moduledoc """
  Lost-kick recovery (P6, second-review finding #4): if the process dies
  between a co-committed write and its post-commit `Enqueue.flush`, or
  `Oban.insert` itself returns `{:error, _}` (historically discarded at
  every call site), the `:pending` outbox row survives (rows are the
  truth) but has no live job. Every tick, scans each configured host's
  outbox for `:pending` chain-head entries and (re-)enqueues them —
  idempotent: an entry that already has a live job just gets a harmless
  extra one (ash_oban's unique-job args dedupe it); an entry that was
  never kicked, or whose kick attempt errored, gets picked up here on this
  tick or (if this tick's own enqueue also errors) the next one, since a
  failed `Enqueue.flush` never changes the row's `:pending` state.
  """
  use GenServer

  require Ash.Query
  require Logger

  alias AshMultiDatalayer.Orchestrator.LocalOutbox
  alias AshMultiDatalayer.Orchestrator.LocalOutbox.Flush
  alias AshMultiDatalayer.Sync.Enqueue

  def start_link(opts) do
    resources = Keyword.fetch!(opts, :resources)

    # L5: `{:global, ...}` is a deliberate single-node-only choice for this
    # sweeper — a genuine peer node (or, in test, a second boot attempt with
    # the same resource set already registered) hits an unavoidable
    # `{:already_started, pid}` collision here. Turn that into a clear,
    # intentional rejection (this app is single-node-only, see
    # `AshMultiDatalayer.Verifiers.RejectMultiNode`/ADR
    # 20260417-single-node-v1) rather than an opaque supervisor-child-start
    # failure — the second node's supervisor still fails to boot either
    # way, but now with an explanation instead of a bare OTP tuple.
    case GenServer.start_link(__MODULE__, resources, name: name(resources)) do
      {:error, {:already_started, _pid}} = error ->
        Logger.error(
          "AshMultiDatalayer.Orchestrator.LocalOutbox.Sweeper failed to start: " <>
            "a sweeper for this resource set is already registered under " <>
            "#{inspect(name(resources))}. ash_multi_datalayer v1 is " <>
            "single-node-only (see ADR 20260417-single-node-v1) — this " <>
            "usually means a peer node tried to join the same distributed " <>
            "Erlang cluster, which is not supported. This node's supervisor " <>
            "will fail to boot as a result."
        )

        error

      other ->
        other
    end
  end

  @doc false
  def run_once(resources) do
    resources
    |> Enum.group_by(&LocalOutbox.outbox_resource/1)
    |> Enum.each(fn {outbox, hosts} ->
      sweep_outbox(outbox, hosts)
      prune_synced(outbox)
    end)

    :ok
  end

  # L12 item 7: `:synced` entries were never pruned — unbounded outbox
  # growth, and `status/1` scans all of a record's entries per poll (a
  # cost that only grows). Every sweep tick also destroys `:synced`
  # entries past the retention window — rows are the truth for `:pending`/
  # `:parked` work, but a `:synced` row has no further purpose once it's
  # old enough that no in-flight stale-check/resolution call could still
  # reference it.
  defp prune_synced(outbox) do
    domain = Ash.Resource.Info.domain(outbox)
    cutoff = DateTime.add(DateTime.utc_now(), -prune_after_ms(), :millisecond)

    outbox
    |> Ash.Query.for_read(:read, %{}, domain: domain, authorize?: false)
    |> Ash.Query.filter(state == :synced and updated_at < ^cutoff)
    |> Ash.read!(authorize?: false)
    |> Enum.each(fn entry ->
      try do
        Ash.destroy!(entry, action: :discard, domain: domain, authorize?: false)
      rescue
        # A concurrent resolution action may have already destroyed/changed
        # this entry between the read above and this destroy — never let a
        # pruning race abort the rest of this tick's cleanup.
        error ->
          Logger.warning(
            "ash_multi_datalayer: LocalOutbox sweeper failed to prune a synced entry for " <>
              "#{inspect(outbox)}: #{Exception.message(error)}"
          )
      end
    end)
  end

  defp prune_after_ms do
    Application.get_env(
      :ash_multi_datalayer,
      :outbox_synced_retention_ms,
      # 7 days
      7 * 24 * 60 * 60 * 1000
    )
  end

  @impl true
  def init(resources) do
    schedule()
    {:ok, resources}
  end

  @impl true
  def handle_info(:sweep, resources) do
    run_once(resources)
    schedule()
    {:noreply, resources}
  end

  defp sweep_outbox(outbox, hosts) do
    domain = Ash.Resource.Info.domain(outbox)
    resources = MapSet.new(hosts, &Atom.to_string/1)

    outbox
    |> Ash.Query.for_read(:read, %{}, domain: domain, authorize?: false)
    |> Ash.Query.filter(state == :pending)
    |> Ash.Query.sort(seq: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&MapSet.member?(resources, &1.resource))
    |> Enum.filter(&(Flush.chain_position(outbox, domain, &1) == :head))
    |> Enum.each(&kick(outbox, &1))
  end

  # Never let a single enqueue failure abort the sweep tick (a raise here
  # would drop every remaining entry in this batch), and never let it
  # vanish silently either — the row stays `:pending`, so the NEXT tick
  # naturally retries it; this only makes today's failure visible.
  defp kick(outbox, entry) do
    case Enqueue.flush(outbox, entry) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "ash_multi_datalayer: LocalOutbox sweeper failed to enqueue a flush job for " <>
            "#{entry.resource} (seq #{entry.seq}): #{inspect(reason)} — the entry stays " <>
            "pending and will be retried on the next sweep tick"
        )

        :telemetry.execute(
          [:ash_multi_datalayer, :local_outbox, :sweeper, :enqueue_failed],
          %{count: 1},
          %{resource: entry.resource, seq: entry.seq, reason: reason}
        )

        :ok
    end
  rescue
    error ->
      Logger.warning(
        "ash_multi_datalayer: LocalOutbox sweeper crashed enqueuing a flush job for " <>
          "#{entry.resource} (seq #{entry.seq}): #{Exception.message(error)} — the entry " <>
          "stays pending and will be retried on the next sweep tick"
      )

      :ok
  end

  defp schedule do
    Process.send_after(self(), :sweep, interval_ms())
  end

  defp interval_ms do
    Application.get_env(:ash_multi_datalayer, :outbox_sweep_interval_ms, 60_000)
  end

  defp name(resources) do
    {:global, {__MODULE__, Enum.sort(resources)}}
  end
end
