defmodule AshMultiDatalayer.Integration.BaselineCrossLayerTest do
  @moduledoc """
  Proof of the Ash / ash_sql BASELINE (no `ash_multi_datalayer` involved): a
  plain `AshPostgres` resource with a relationship aggregate over a plain
  `Ash.DataLayer.Ets` resource fails — ash_sql builds an in-DB join and asks the
  ETS related resource for an `%Ecto.Query{}` it cannot produce. This is exactly
  the limitation `SqlPassthrough` turns into a clean error (or a working join for
  a same-repo SQL child).
  """
  use AshMultiDatalayer.DataCase, async: false

  require Ash.Query

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshMultiDatalayer.Integration.BaselineCrossLayerTest.EtsThing
      resource AshMultiDatalayer.Integration.BaselineCrossLayerTest.PgOwner
    end
  end

  defmodule EtsThing do
    use Ash.Resource, domain: Domain, data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_primary_key :id
      attribute :owner_id, :uuid, public?: true
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]
    end
  end

  defmodule PgOwner do
    use Ash.Resource, domain: Domain, data_layer: AshPostgres.DataLayer

    postgres do
      table "mdl_authors"
      repo(AshMultiDatalayer.TestRepo)
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
    end

    relationships do
      has_many :things, EtsThing, destination_attribute: :owner_id, public?: true
    end

    aggregates do
      count :thing_count, :things do
        public? true
      end
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]
    end
  end

  test "a plain AshPostgres aggregate over a plain ETS related resource crashes — Ash's baseline" do
    Ash.DataLayer.Ets.stop(EtsThing)

    owner = PgOwner |> Ash.Changeset.for_create(:create, %{name: "x"}) |> Ash.create!()
    EtsThing |> Ash.Changeset.for_create(:create, %{owner_id: owner.id}) |> Ash.create!()

    error =
      catch_error(
        PgOwner
        |> Ash.Query.filter(id == ^owner.id)
        |> Ash.Query.load(:thing_count)
        |> Ash.read_one!()
      )

    # No MDL, no graceful fold fallback: ash_sql tried to splice the ETS query
    # into a join and blew up on the missing `__ash_bindings__`. This is the
    # limitation `SqlPassthrough` intercepts for MDL-wrapped related resources
    # (turning it into a clean error, or a working join for same-repo SQL).
    assert Exception.message(error) =~ "__ash_bindings__"
    assert Exception.message(error) =~ "Ets.Query"
  end
end
