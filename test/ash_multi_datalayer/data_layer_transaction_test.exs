defmodule AshMultiDatalayer.DataLayerTransactionTest do
  @moduledoc """
  M-8: `AshMultiDatalayer.DataLayer.rollback/2`'s fallback (a layer with no
  `rollback/2` of its own) signals failure via `throw({:rollback, term})` —
  the idiom `Ecto.Repo.transaction/2` also uses. Nothing caught that throw in
  `transaction/4`'s own fallback (a layer with no `transaction/4` either): it
  escaped as an uncaught `nocatch` crash instead of `{:error, term}`.
  """
  use ExUnit.Case, async: true

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered?(true)
    end
  end

  # Both layers are Ets — neither implements `transaction/4`/`rollback/2` —
  # so `transaction_layer/1` (write_order's head) resolves to a layer that
  # exercises the shell's own fallback, not a real Ecto transaction.
  defmodule NoTxnPost do
    @moduledoc false
    use Ash.Resource,
      domain: AshMultiDatalayer.DataLayerTransactionTest.Domain,
      data_layer: AshMultiDatalayer.DataLayer

    multi_data_layer do
      layer(:cache, Ash.DataLayer.Ets)
      layer(:source, Ash.DataLayer.Ets)
      read_order([:cache, :source])
      write_order([:source, :cache])
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read, :destroy, create: :*, update: :*])
    end
  end

  test "rollback/2's throw fallback is caught by transaction/4's own fallback" do
    assert {:error, :boom} =
             AshMultiDatalayer.DataLayer.transaction(
               NoTxnPost,
               fn -> AshMultiDatalayer.DataLayer.rollback(NoTxnPost, :boom) end,
               nil,
               %{type: :test, metadata: %{}}
             )
  end

  test "a fun that returns normally still returns {:ok, result}" do
    assert {:ok, :done} =
             AshMultiDatalayer.DataLayer.transaction(
               NoTxnPost,
               fn -> :done end,
               nil,
               %{type: :test, metadata: %{}}
             )
  end
end
