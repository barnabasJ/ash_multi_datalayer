defmodule TodoClient.MdlCase do
  @moduledoc """
  Case template for the multi-datalayer proof tests: resets server data, all
  client-side layered state (cache, coverage ledger, kill-switch), the RPC
  counter, and forwards the library's telemetry to the test process as
  `{:mdl, event, measurements, metadata}` messages.
  """
  use ExUnit.CaseTemplate

  alias TodoClient.Test.CountingRouter

  @client_resources [
    TodoClient.Remote.Todo,
    TodoClient.Remote.TodoList,
    TodoClient.Remote.User,
    TodoClient.Test.SampledTodo
  ]

  @events [
    [:ash_multi_datalayer, :read, :hit],
    [:ash_multi_datalayer, :read, :miss],
    [:ash_multi_datalayer, :read, :backfill],
    [:ash_multi_datalayer, :read, :divergence_detected],
    [:ash_multi_datalayer, :write, :applied],
    [:ash_multi_datalayer, :write, :failed_at_layer],
    [:ash_multi_datalayer, :ledger, :invalidated]
  ]

  using do
    quote do
      import TodoClient.MdlCase

      require Ash.Query

      alias TodoClient.Remote.{Todo, TodoList, User}
      alias TodoClient.Test.{CountingRouter, SampledTodo}
    end
  end

  setup do
    # Server truth: wipe and reseed.
    Enum.each(Ash.read!(TodoServer.Todo), &Ash.destroy!/1)
    Enum.each(Ash.read!(TodoServer.TodoList), &Ash.destroy!/1)
    Enum.each(Ash.read!(TodoServer.User), &Ash.destroy!/1)

    # Client layered state: coverage ledgers + kill-switches (library), and
    # the Ets cache tables (layer-specific cleanup is the app's job).
    Enum.each(@client_resources, fn resource ->
      AshMultiDatalayer.TestSupport.reset!(resource)
      Ash.DataLayer.Ets.stop(resource)
    end)

    CountingRouter.reset!()

    handler = "mdl-case-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach_many(
      handler,
      @events,
      fn event, measurements, metadata, _config ->
        send(parent, {:mdl, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    user = Ash.create!(TodoServer.User, %{name: "Ada"})
    list = Ash.create!(TodoServer.TodoList, %{name: "Errands", user_id: user.id})
    other_list = Ash.create!(TodoServer.TodoList, %{name: "Later", user_id: user.id})

    %{user: user, list: list, other_list: other_list}
  end

  @doc "Creates a todo directly on the server (out-of-band for the client)."
  def server_create_todo!(attrs) do
    Ash.create!(TodoServer.Todo, attrs)
  end
end
