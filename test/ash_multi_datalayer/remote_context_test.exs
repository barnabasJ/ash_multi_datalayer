defmodule AshMultiDatalayer.RemoteContextTest do
  @moduledoc """
  The context provider MDL threads onto target-layer reads/writes an orchestrator
  performs on the app's behalf (LocalOutbox flush/hydration/stale-check), so a
  networked target authenticates even with no request actor in scope.
  """
  use ExUnit.Case, async: false

  alias AshMultiDatalayer.RemoteContext

  setup do
    on_exit(fn -> Application.delete_env(:ash_multi_datalayer, :remote_context) end)
    :ok
  end

  describe "resolve/0" do
    test "defaults to an empty map (no config → behaviour unchanged)" do
      Application.delete_env(:ash_multi_datalayer, :remote_context)
      assert RemoteContext.resolve() == %{}
    end

    test "returns a configured static map as-is" do
      ctx = %{ash_remote: %{headers: %{"authorization" => "Bearer abc"}}}
      Application.put_env(:ash_multi_datalayer, :remote_context, ctx)
      assert RemoteContext.resolve() == ctx
    end

    test "invokes an {m,f,a} provider on every call (fresh, rotatable)" do
      Application.put_env(:ash_multi_datalayer, :remote_context, {__MODULE__, :dynamic_ctx, []})

      assert %{ash_remote: %{headers: %{"authorization" => "Bearer " <> _}}} =
               RemoteContext.resolve()
    end

    test "invokes a 0-arity fun provider" do
      Application.put_env(:ash_multi_datalayer, :remote_context, fn -> %{a: 1} end)
      assert RemoteContext.resolve() == %{a: 1}
    end
  end

  describe "merge/1" do
    test "deep-merges the resolved context, resolved winning leaf conflicts" do
      Application.put_env(:ash_multi_datalayer, :remote_context, %{
        private: %{actor: :from_config},
        ash_remote: %{headers: %{"authorization" => "Bearer z"}}
      })

      merged = RemoteContext.merge(%{private: %{tenant: "t", actor: :from_caller}})

      # sibling caller keys preserved, nested map deep-merged, resolved wins on the leaf
      assert merged.private.tenant == "t"
      assert merged.private.actor == :from_config
      assert merged.ash_remote.headers["authorization"] == "Bearer z"
    end

    test "tolerates a nil base context" do
      Application.put_env(:ash_multi_datalayer, :remote_context, %{x: 1})
      assert RemoteContext.merge(nil) == %{x: 1}
    end
  end

  def dynamic_ctx,
    do: %{
      ash_remote: %{headers: %{"authorization" => "Bearer #{System.unique_integer([:positive])}"}}
    }
end
