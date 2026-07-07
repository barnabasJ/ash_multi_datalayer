defmodule AshMultiDatalayer.Notifiers.ExternalChangeExitTest do
  @moduledoc """
  M-8: `ExternalChange.notify/1` rescues raised exceptions but, pre-fix,
  neither `:exit` nor `:throw` — a `GenServer.call` timeout (or any other
  linked-process failure) inside a reaction exits, not raises, and would
  escape uncaught, violating the "never crash the notifying socket" contract.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias AshMultiDatalayer.Notifiers.ExternalChange

  defmodule ExitingOrchestrator do
    @moduledoc false
    @behaviour AshMultiDatalayer.Orchestrator

    @impl true
    def read(_query, _resource), do: {:ok, []}
    @impl true
    def create(_resource, _changeset), do: {:error, :unused}
    @impl true
    def update(_resource, _changeset), do: {:error, :unused}
    @impl true
    def upsert(_resource, _changeset, _keys, _identity), do: {:error, :unused}
    @impl true
    def destroy(_resource, _changeset), do: {:error, :unused}
    @impl true
    def authority(_resource), do: Ash.DataLayer.Ets
    @impl true
    def transaction_layer(_resource), do: Ash.DataLayer.Ets
    @impl true
    def can?(_resource, _feature), do: false
    @impl true
    def handle_external_change(_resource, _notification), do: exit(:reaction_timeout)
    @impl true
    def handle_external_gap(_resource, _tenant), do: :ok
    @impl true
    def child_specs(_resources), do: []
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered?(true)
    end
  end

  defmodule ExitingPost do
    @moduledoc false
    use Ash.Resource,
      domain: AshMultiDatalayer.Notifiers.ExternalChangeExitTest.Domain,
      data_layer: AshMultiDatalayer.DataLayer,
      notifiers: [AshMultiDatalayer.Notifiers.ExternalChange]

    multi_data_layer do
      orchestrator(AshMultiDatalayer.Notifiers.ExternalChangeExitTest.ExitingOrchestrator)
      layer(:only, Ash.DataLayer.Ets)
      read_order([:only])
      write_order([:only])
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read, :destroy])
    end
  end

  test "an :exit inside the orchestrator's reaction is caught, warned, and swallowed" do
    notification = %Ash.Notifier.Notification{
      resource: ExitingPost,
      data: %ExitingPost{},
      metadata: %{"ash_remote" => %{"origin" => "remote"}}
    }

    log =
      capture_log(fn ->
        assert :ok = ExternalChange.notify(notification)
      end)

    assert log =~ "inbound reaction"
    assert log =~ "reaction_timeout"
  end

  test "local unmarked notifications are ignored" do
    notification = %Ash.Notifier.Notification{resource: ExitingPost, data: %ExitingPost{}}

    log = capture_log(fn -> assert :ok = ExternalChange.notify(notification) end)

    assert log == ""
  end

  # B4: the actual producer (`ash_remote`'s `Realtime.Inbound.metadata/1`)
  # emits `Map.put(user_meta, "ash_remote", %{origin: :remote, id: ...,
  # occurred_at: ...})` — a STRING outer key, ATOM inner keys. Neither the
  # all-string nor the all-atom synthetic shape above (both already fixed)
  # covers this mixed shape — unfixed code drops every real replayed
  # notification, so the reaction (invalidate/refresh) never runs.
  test "the real producer's mixed-key metadata shape (string outer, atom inner) is recognized" do
    notification = %Ash.Notifier.Notification{
      resource: ExitingPost,
      data: %ExitingPost{},
      metadata: %{
        "ash_remote" => %{origin: :remote, id: "abc", occurred_at: "2026-07-07T00:00:00Z"}
      }
    }

    log =
      capture_log(fn ->
        assert :ok = ExternalChange.notify(notification)
      end)

    assert log =~ "inbound reaction"
    assert log =~ "reaction_timeout"
  end

  # B4: the `external?: true` marker clause matched no known producer and is
  # removed — confirm it stays removed (not silently dead) rather than
  # accidentally marking something external.
  test "a bare external?: true metadata field (the removed dead clause) does not mark a notification external" do
    notification = %Ash.Notifier.Notification{
      resource: ExitingPost,
      data: %ExitingPost{},
      metadata: %{external?: true}
    }

    log = capture_log(fn -> assert :ok = ExternalChange.notify(notification) end)

    assert log == ""
  end
end
