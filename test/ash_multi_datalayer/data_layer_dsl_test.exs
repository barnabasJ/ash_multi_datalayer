defmodule AshMultiDatalayer.DataLayerDslTest do
  use ExUnit.Case, async: true

  alias AshMultiDatalayer.DataLayer.Info
  alias AshMultiDatalayer.Layer

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered?(true)
    end
  end

  defmodule Post do
    use Ash.Resource,
      domain: Domain,
      data_layer: AshMultiDatalayer.DataLayer

    multi_data_layer do
      layer(:l1, Ash.DataLayer.Ets)
      layer(:l2, Ash.DataLayer.Ets)

      read_order([:l1, :l2])
      write_order([:l2, :l1])
      ledger_max_entries(500)
      divergence_sampler(0.25)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
      attribute(:age, :integer, public?: true)
    end

    actions do
      defaults([:read, :destroy, create: :*, update: :*])
    end
  end

  test "layers are parsed as Layer structs in declaration order" do
    assert [
             %Layer{name: :l1, module: Ash.DataLayer.Ets},
             %Layer{name: :l2, module: Ash.DataLayer.Ets}
           ] = Info.layers(Post)

    assert Info.layer_modules(Post) == [Ash.DataLayer.Ets, Ash.DataLayer.Ets]
    assert Info.layer!(Post, :l1) == Ash.DataLayer.Ets
  end

  test "layer! raises on undeclared names" do
    assert_raise ArgumentError, ~r/no layer named :nope/, fn ->
      Info.layer!(Post, :nope)
    end
  end

  test "order lists and options are exposed" do
    assert Info.read_order(Post) == [:l1, :l2]
    assert Info.write_order(Post) == [:l2, :l1]
    assert Info.read_layer_modules(Post) == [Ash.DataLayer.Ets, Ash.DataLayer.Ets]
    assert Info.write_layer_modules(Post) == [Ash.DataLayer.Ets, Ash.DataLayer.Ets]
    assert Info.ledger_max_entries(Post) == 500
    assert Info.divergence_sampler(Post) == 0.25
  end

  test "defaults apply when options are omitted" do
    defmodule Minimal do
      use Ash.Resource,
        domain: Domain,
        data_layer: AshMultiDatalayer.DataLayer

      multi_data_layer do
        layer(:only, Ash.DataLayer.Ets)
        read_order([:only])
        write_order([:only])
      end

      attributes do
        uuid_primary_key(:id)
      end
    end

    assert Info.ledger_max_entries(Minimal) == 10_000
    assert Info.divergence_sampler(Minimal) == 0.0
  end

  test "missing read_order fails to compile with an error naming the option" do
    assert_raise Spark.Error.DslError, ~r/read_order/, fn ->
      defmodule MissingReadOrder do
        use Ash.Resource,
          domain: AshMultiDatalayer.DataLayerDslTest.Domain,
          data_layer: AshMultiDatalayer.DataLayer

        multi_data_layer do
          layer(:l1, Ash.DataLayer.Ets)
          write_order([:l1])
        end

        attributes do
          uuid_primary_key(:id)
        end
      end
    end
  end

  test "can? answers from the declared layers" do
    # Ets supports reads/creates; nothing supports :transact through Ets.
    assert AshMultiDatalayer.DataLayer.can?(Post, :read)
    assert AshMultiDatalayer.DataLayer.can?(Post, :create)
    refute AshMultiDatalayer.DataLayer.can?(Post, :transact)
  end

  test "unknown entities inside the section fail helpfully" do
    # Spark surfaces unknown DSL calls as a CompileError naming the call.
    assert_raise CompileError, fn ->
      defmodule UnknownEntity do
        use Ash.Resource,
          domain: AshMultiDatalayer.DataLayerDslTest.Domain,
          data_layer: AshMultiDatalayer.DataLayer

        multi_data_layer do
          layer(:l1, Ash.DataLayer.Ets)
          read_order([:l1])
          write_order([:l1])
          not_an_option(:whoops)
        end

        attributes do
          uuid_primary_key(:id)
        end
      end
    end
  end
end
