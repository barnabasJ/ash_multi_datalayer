defmodule AshMultiDatalayer.KillSwitchTest do
  use ExUnit.Case, async: false

  defmodule ResourceA do
  end

  defmodule ResourceB do
  end

  setup do
    on_exit(fn ->
      AshMultiDatalayer.enable!(ResourceA)
      AshMultiDatalayer.enable!(ResourceB)
    end)
  end

  test "resources are enabled by default" do
    assert AshMultiDatalayer.enabled?(ResourceA)
  end

  test "disable!/enable! flip the flag for one resource only" do
    :ok = AshMultiDatalayer.disable!(ResourceA)

    refute AshMultiDatalayer.enabled?(ResourceA)
    assert AshMultiDatalayer.enabled?(ResourceB)

    :ok = AshMultiDatalayer.enable!(ResourceA)
    assert AshMultiDatalayer.enabled?(ResourceA)
  end

  test "enable! erases the persistent_term key rather than storing :enabled" do
    :ok = AshMultiDatalayer.disable!(ResourceA)
    :ok = AshMultiDatalayer.enable!(ResourceA)

    assert :persistent_term.get({:ash_multi_datalayer, ResourceA}, :missing) == :missing
  end

  test "concurrent flips never crash" do
    1..50
    |> Task.async_stream(fn i ->
      if rem(i, 2) == 0 do
        AshMultiDatalayer.disable!(ResourceA)
      else
        AshMultiDatalayer.enable!(ResourceA)
      end

      AshMultiDatalayer.enabled?(ResourceA)
    end)
    |> Stream.run()
  end
end
