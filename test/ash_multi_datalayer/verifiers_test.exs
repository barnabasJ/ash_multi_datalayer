defmodule AshMultiDatalayer.VerifiersTest do
  # Spark 2.7 surfaces verifier failures as compiler diagnostics (warnings
  # that fail --warnings-as-errors builds), not runtime raises — so these
  # tests call each verifier directly on the resource's DSL config, plus two
  # end-to-end tests through Spark's test collector proving the wiring
  # (P2). async: false — two test_collector-using tests are safer
  # serialized than concurrent (the collector is a registration keyed on
  # the receiving pid, not scoped per-test).
  use ExUnit.Case, async: false

  alias AshMultiDatalayer.Verifiers.{
    RejectFieldPolicies,
    RejectMultiNode,
    ValidateAggregateOverrides,
    ValidateLayers,
    ValidateMultitenancy,
    ValidateSolverSupportedPredicates
  }

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered? true
    end
  end

  defmodule NoTenantLayer do
    @moduledoc false
    @behaviour Ash.DataLayer

    @impl true
    def can?(_resource, :multitenancy), do: false
    def can?(_resource, _feature), do: true

    @impl true
    def resource_to_query(resource, domain), do: %{resource: resource, domain: domain}
  end

  defp define(body, use_opts \\ []) do
    module = :"Elixir.AshMultiDatalayer.VerifiersTest.R#{System.unique_integer([:positive])}"

    opts =
      Keyword.merge(
        [
          domain: AshMultiDatalayer.VerifiersTest.Domain,
          data_layer: AshMultiDatalayer.DataLayer
        ],
        use_opts
      )

    Module.create(
      module,
      quote do
        use Ash.Resource, unquote(opts)

        unquote(body)

        attributes do
          uuid_primary_key :id
          attribute :name, :string, public?: true
        end
      end,
      Macro.Env.location(__ENV__)
    )

    module
  end

  defp error_message({:error, %Spark.Error.DslError{message: message}}), do: message
  defp error_message(other), do: flunk("expected {:error, %DslError{}}, got: #{inspect(other)}")

  describe "ValidateLayers" do
    test "a valid two-layer resource verifies" do
      module =
        define(
          quote do
            multi_data_layer do
              layer(:l1, Ash.DataLayer.Ets)
              layer(:l2, Ash.DataLayer.Ets)
              read_order([:l1, :l2])
              write_order([:l2, :l1])
            end
          end
        )

      assert :ok = ValidateLayers.verify(module.spark_dsl_config())
    end

    test "duplicate layer names are rejected" do
      module =
        define(
          quote do
            multi_data_layer do
              layer(:l1, Ash.DataLayer.Ets)
              layer(:l1, Ash.DataLayer.Ets)
              read_order([:l1])
              write_order([:l1])
            end
          end
        )

      assert error_message(ValidateLayers.verify(module.spark_dsl_config())) =~
               "duplicate layer names: [:l1]"
    end

    test "order lists referencing undeclared layers are rejected" do
      module =
        define(
          quote do
            multi_data_layer do
              layer(:l1, Ash.DataLayer.Ets)
              read_order([:nope])
              write_order([:l1])
            end
          end
        )

      assert error_message(ValidateLayers.verify(module.spark_dsl_config())) =~
               "read_order references undeclared layers [:nope]"
    end

    test "layer modules must implement Ash.DataLayer" do
      module =
        define(
          quote do
            multi_data_layer do
              layer(:l1, Enum)
              read_order([:l1])
              write_order([:l1])
            end
          end
        )

      assert error_message(ValidateLayers.verify(module.spark_dsl_config())) =~
               "does not implement Ash.DataLayer"
    end

    test "a layer with required section options needs its extension listed" do
      module =
        define(
          quote do
            multi_data_layer do
              layer(:l1, Ash.DataLayer.Ets)
              layer(:l2, AshPostgres.DataLayer)
              read_order([:l1, :l2])
              write_order([:l2, :l1])
            end
          end
        )

      message = error_message(ValidateLayers.verify(module.spark_dsl_config()))
      assert message =~ "requires its DSL section"
      assert message =~ "extensions: [AshPostgres.DataLayer]"
    end

    test "cache layers must support upserts" do
      module =
        define(
          quote do
            multi_data_layer do
              layer(:l1, Ash.DataLayer.Simple)
              layer(:l2, Ash.DataLayer.Ets)
              read_order([:l1, :l2])
              write_order([:l2, :l1])
            end
          end
        )

      assert error_message(ValidateLayers.verify(module.spark_dsl_config())) =~
               "does not support upserts"
    end

    # A0 retained regression (#22): landed but untested — the authority-order
    # verifier (proven_coverage_authority_order/1) requires ProvenCoverage's
    # read source-of-truth (last read_order) to equal its write authority
    # (hd write_order). A mismatch here would let reads and writes disagree
    # about which layer is authoritative, silently corrupting the coverage
    # invariant.
    test "ProvenCoverage's read source authority must equal the write authority" do
      module =
        define(
          quote do
            multi_data_layer do
              layer(:l1, Ash.DataLayer.Ets)
              layer(:l2, Ash.DataLayer.Ets)
              layer(:l3, Ash.DataLayer.Ets)
              read_order([:l1, :l2])
              write_order([:l3, :l1])
            end
          end
        )

      assert error_message(ValidateLayers.verify(module.spark_dsl_config())) =~
               "requires the read source authority (last read_order) to equal " <>
                 "the write authority (hd write_order)"
    end

    test "a matching read/write authority verifies" do
      module =
        define(
          quote do
            multi_data_layer do
              layer(:l1, Ash.DataLayer.Ets)
              layer(:l2, Ash.DataLayer.Ets)
              read_order([:l1, :l2])
              write_order([:l2, :l1])
            end
          end
        )

      assert :ok = ValidateLayers.verify(module.spark_dsl_config())
    end
  end

  describe "ValidateMultitenancy" do
    test "a multitenant resource with tenant-capable layers verifies" do
      module =
        define(
          quote do
            multi_data_layer do
              layer(:l1, Ash.DataLayer.Ets)
              read_order([:l1])
              write_order([:l1])
            end

            multitenancy do
              strategy :attribute
              attribute :name
            end
          end
        )

      assert :ok = ValidateMultitenancy.verify(module.spark_dsl_config())
    end

    test "a tenant-incapable layer is rejected on a multitenant resource" do
      module =
        define(
          quote do
            multi_data_layer do
              layer(:l1, AshMultiDatalayer.VerifiersTest.NoTenantLayer)
              read_order([:l1])
              write_order([:l1])
            end

            multitenancy do
              strategy :attribute
              attribute :name
            end
          end
        )

      assert error_message(ValidateMultitenancy.verify(module.spark_dsl_config())) =~
               "does not support multitenancy"
    end
  end

  describe "RejectFieldPolicies" do
    defp define_with_field_policies(read_order) do
      define(
        quote do
          multi_data_layer do
            layer(:l1, Ash.DataLayer.Ets)
            layer(:l2, Ash.DataLayer.Ets)
            read_order(unquote(read_order))
            write_order([:l2, :l1])
          end

          field_policies do
            field_policy :name do
              authorize_if always()
            end
          end

          policies do
            policy always() do
              authorize_if always()
            end
          end
        end,
        authorizers: [Ash.Policy.Authorizer]
      )
    end

    test "field_policies + multi-layer read_order is rejected" do
      module = define_with_field_policies([:l1, :l2])

      assert error_message(RejectFieldPolicies.verify(module.spark_dsl_config())) =~
               "field_policies cannot be combined"
    end

    test "field_policies with single-layer read_order verifies" do
      module = define_with_field_policies([:l2])
      assert :ok = RejectFieldPolicies.verify(module.spark_dsl_config())
    end

    # P2: pins the compile posture the README/ADR now document — a plain
    # `mix compile` does NOT hard-fail on this rejection (the module
    # compiles here without raising), it only reaches the compiler as a
    # diagnostic Spark's `:test_collector` hook intercepts below — which is
    # exactly the shape that fails a `--warnings-as-errors` build and is
    # silently accepted (serving a cache row materialized under a different
    # actor, unredacted) without it.
    test "the rejection reaches the compiler diagnostic path a --warnings-as-errors build enforces" do
      Process.put({Spark.Dsl, :test_collector}, self())

      try do
        _module = define_with_field_policies([:l1, :l2])

        message =
          receive do
            {Spark.Dsl, :verifier_errors, _mod, errors} when errors != [] ->
              [%Spark.Error.DslError{message: message} | _] = errors
              message
          after
            10_000 -> flunk("no verifier_errors message received")
          end

        assert message =~ "field_policies cannot be combined"
      after
        Process.delete({Spark.Dsl, :test_collector})
      end
    end
  end

  describe "RejectMultiNode" do
    test "acked single-node config verifies (test config sets the ack)" do
      module =
        define(
          quote do
            multi_data_layer do
              layer(:l1, Ash.DataLayer.Ets)
              read_order([:l1])
              write_order([:l1])
            end
          end
        )

      assert :ok = RejectMultiNode.verify(module.spark_dsl_config())
    end

    test "without the ack it warns" do
      Application.put_env(:ash_multi_datalayer, :assume_single_node, false)

      try do
        assert {:warn, message} = RejectMultiNode.verify(%{})
        assert message =~ "single-node-only"
      after
        Application.put_env(:ash_multi_datalayer, :assume_single_node, true)
      end
    end
  end

  describe "ValidateAggregateOverrides" do
    test "an override naming a real aggregate verifies" do
      module =
        define(
          quote do
            multi_data_layer do
              layer(:l1, Ash.DataLayer.Ets)
              layer(:l2, Ash.DataLayer.Ets)
              read_order([:l1, :l2])
              write_order([:l2, :l1])
              sql_join_aggregate_overrides([:thing_count])
            end

            relationships do
              has_many :things, AshMultiDatalayer.Test.Resources.TestPost,
                destination_attribute: :author_id
            end

            aggregates do
              count :thing_count, :things
            end
          end
        )

      assert :ok = ValidateAggregateOverrides.verify(module.spark_dsl_config())
    end

    test "an override naming something that isn't an aggregate is rejected" do
      module =
        define(
          quote do
            multi_data_layer do
              layer(:l1, Ash.DataLayer.Ets)
              read_order([:l1])
              write_order([:l1])
              sql_join_aggregate_overrides([:not_an_aggregate])
            end
          end
        )

      assert error_message(ValidateAggregateOverrides.verify(module.spark_dsl_config())) =~
               "not an aggregate"
    end

    # B5: `local_evaluation_overrides` holds CALCULATION names, not aggregate
    # names (data_layer.ex's doc, consumed at value_merge.ex:57) — unfixed
    # code validates it against `Ash.Resource.Info.aggregates/1`, so ANY
    # legitimate calculation override fails compilation.
    test "an override naming a real calculation in local_evaluation_overrides verifies" do
      module =
        define(
          quote do
            multi_data_layer do
              layer(:l1, Ash.DataLayer.Ets)
              layer(:l2, Ash.DataLayer.Ets)
              read_order([:l1, :l2])
              write_order([:l2, :l1])
              local_evaluation_overrides([:overdue?])
            end

            calculations do
              calculate :overdue?, :boolean, expr(false)
            end
          end
        )

      assert :ok = ValidateAggregateOverrides.verify(module.spark_dsl_config())
    end

    test "an override naming something that isn't a calculation in local_evaluation_overrides is rejected" do
      module =
        define(
          quote do
            multi_data_layer do
              layer(:l1, Ash.DataLayer.Ets)
              read_order([:l1])
              write_order([:l1])
              local_evaluation_overrides([:not_a_calculation])
            end
          end
        )

      assert error_message(ValidateAggregateOverrides.verify(module.spark_dsl_config())) =~
               "not a calculation"
    end

    test "fold_aggregate_overrides still validates against aggregate names" do
      module =
        define(
          quote do
            multi_data_layer do
              layer(:l1, Ash.DataLayer.Ets)
              read_order([:l1])
              write_order([:l1])
              fold_aggregate_overrides([:not_an_aggregate])
            end
          end
        )

      assert error_message(ValidateAggregateOverrides.verify(module.spark_dsl_config())) =~
               "not an aggregate"
    end
  end

  describe "ValidateSolverSupportedPredicates" do
    test "a supported base_filter verifies quietly" do
      module =
        define(
          quote do
            multi_data_layer do
              layer(:l1, Ash.DataLayer.Ets)
              layer(:l2, Ash.DataLayer.Ets)
              read_order([:l1, :l2])
              write_order([:l2, :l1])
            end

            resource do
              base_filter name: [eq: "x"]
            end
          end
        )

      assert :ok = ValidateSolverSupportedPredicates.verify(module.spark_dsl_config())
    end

    test "an unsupported base_filter warns" do
      module =
        define(
          quote do
            multi_data_layer do
              layer(:l1, Ash.DataLayer.Ets)
              layer(:l2, Ash.DataLayer.Ets)
              read_order([:l1, :l2])
              write_order([:l2, :l1])
            end

            resource do
              base_filter name: [contains: "x"]
            end
          end
        )

      assert {:warn, message} =
               ValidateSolverSupportedPredicates.verify(module.spark_dsl_config())

      assert message =~ "outside the subsumption"
    end
  end

  describe "end-to-end wiring through Spark" do
    test "verifier errors reach the compiler diagnostics" do
      Process.put({Spark.Dsl, :test_collector}, self())

      try do
        module =
          define(
            quote do
              multi_data_layer do
                layer(:l1, Ash.DataLayer.Ets)
                layer(:l1, Ash.DataLayer.Ets)
                read_order([:l1])
                write_order([:l1])
              end
            end
          )

        assert_receive {Spark.Dsl, :verifier_errors, ^module,
                        [%Spark.Error.DslError{message: message}]}

        assert message =~ "duplicate layer names"
      after
        Process.delete({Spark.Dsl, :test_collector})
      end
    end
  end
end
