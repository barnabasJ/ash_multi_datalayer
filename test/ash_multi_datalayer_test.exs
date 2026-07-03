defmodule AshMultiDatalayerTest do
  use ExUnit.Case, async: true

  test "stub data layer advertises no capabilities yet" do
    refute AshMultiDatalayer.DataLayer.can?(nil, :read)
  end
end
