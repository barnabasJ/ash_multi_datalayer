defmodule AshMultiDatalayer.DataLayerCodegenTest do
  use ExUnit.Case, async: true

  describe "disambiguate_name/2" do
    test "suffixes an explicit --name so postgres and sqlite codegen never collide" do
      args = ["--name", "add_local_events_and_outbox", "--quiet"]

      postgres_args = AshMultiDatalayer.DataLayer.disambiguate_name(args, "postgres")
      sqlite_args = AshMultiDatalayer.DataLayer.disambiguate_name(args, "sqlite")

      assert postgres_args == [
               "--name",
               "add_local_events_and_outbox_multi_datalayer_postgres",
               "--quiet"
             ]

      assert sqlite_args == [
               "--name",
               "add_local_events_and_outbox_multi_datalayer_sqlite",
               "--quiet"
             ]

      # The whole point: the two suffixed names must differ from each other
      # (and from the original), or the collision this exists to prevent
      # would still happen.
      assert postgres_args != sqlite_args
      assert postgres_args != args
    end

    test "leaves args untouched when no --name is present (e.g. --dev mode)" do
      args = ["--dev", "--quiet"]

      assert AshMultiDatalayer.DataLayer.disambiguate_name(args, "postgres") == args
    end
  end
end
