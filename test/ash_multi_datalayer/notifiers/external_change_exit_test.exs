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
end
