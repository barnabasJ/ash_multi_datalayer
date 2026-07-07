defmodule AshMultiDatalayer.Notifiers.ExternalChange do
  @moduledoc """
  A strategy-agnostic `Ash.Notifier` that turns an inbound change notification on
  a multi-datalayer resource into the reaction its orchestrator prescribes.

  A realtime transport (e.g. `AshRemote.Realtime.Inbound`) replays each
  server-side change as a local Ash notification on the client resource. Listing
  this notifier on such a resource routes that notification through
  `Info.orchestrator/1` to the strategy's `handle_external_change/2`:

    * **ProvenCoverage** invalidates the covered rows, so the next read is a
      genuine miss that refetches the fresh value.
    * **LocalOutbox** refreshes that row into the local authority (skipping a PK
      with unflushed local edits — the dirty-chain rule), so an online replica
      converges without a poll.

  One notifier, two strategy-appropriate reactions — the inbound half of the
  same seam `Orchestrator.handle_external_change/2` defines. It performs no
  data-layer-specific work itself; a resource with an orchestrator that treats
  the callback as a no-op simply ignores the notification.

  Pair it with an application-level notifier/bridge (see the example's
  `RealtimeBridge`) when a LiveView must also re-render after the reaction.
  """
  use Ash.Notifier

  require Logger

  alias AshMultiDatalayer.DataLayer.Info

  @impl Ash.Notifier
  def notify(%Ash.Notifier.Notification{resource: resource} = notification) do
    if replayed_external?(notification) do
      {orchestrator, _opts} = Info.orchestrator(resource)

      if function_exported?(orchestrator, :handle_external_change, 2) do
        orchestrator.handle_external_change(resource, notification)
      end
    end

    :ok
  rescue
    # An inbound reaction must never crash the notifying transaction/socket; a
    # dropped refresh/invalidation self-heals on the next read or gap sweep.
    # But it must not be *silent* — a persistently-failing reaction would look
    # like working realtime while every push is quietly dropped (the exact
    # shape of a cross-client sync regression). Warn with the reaction and the
    # stacktrace so the failure is diagnosable, then still swallow.
    error ->
      warn_and_drop(resource, Exception.message(error), __STACKTRACE__)
      :ok
  catch
    # A `GenServer.call` timeout (or any other linked-process failure) inside
    # a reaction exits, not raises — `rescue` alone never sees it, so it
    # escaped and could crash the notifying socket (M-8's `ExternalChange`
    # counterpart: same "never crash the caller" contract, wider failure
    # class). Same warn-then-swallow posture for `:exit`/`:throw` as for a
    # rescued raise.
    kind, reason ->
      warn_and_drop(resource, "#{kind}: #{inspect(reason)}", __STACKTRACE__)
      :ok
  end

  defp warn_and_drop(resource, reason, stacktrace) do
    Logger.warning(
      "ash_multi_datalayer: inbound reaction for #{inspect(resource)} failed and was " <>
        "dropped (self-heals on the next read/gap sweep): #{reason}\n" <>
        Exception.format_stacktrace(stacktrace)
    )
  end

  defp replayed_external?(%{metadata: %{"ash_remote" => %{"origin" => origin}}})
       when origin in [:remote, "remote"],
       do: true

  defp replayed_external?(%{metadata: %{ash_remote: %{origin: origin}}})
       when origin in [:remote, "remote"],
       do: true

  defp replayed_external?(%{metadata: %{external?: true}}), do: true
  defp replayed_external?(_), do: false
end
