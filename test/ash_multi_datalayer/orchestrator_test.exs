defmodule AshMultiDatalayer.OrchestratorTest do
  @moduledoc """
  Unit coverage for the Phase 1 orchestrator seam: the `orchestrator` DSL
  option, `Info.orchestrator/1` resolution + alias forwarding, ProvenCoverage's
  structural answers, and the `ValidateOrchestrator` verifier.
  """
  use ExUnit.Case, async: true

  alias AshMultiDatalayer.DataLayer.Info
  alias AshMultiDatalayer.Orchestrator.ProvenCoverage

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered?(true)
    end
  end

  defmodule DefaultPost do
    use Ash.Resource, domain: Domain, data_layer: AshMultiDatalayer.DataLayer

    multi_data_layer do
      layer(:cache, Ash.DataLayer.Ets)
      layer(:source, Ash.DataLayer.Ets)
      read_order([:cache, :source])
      write_order([:source, :cache])
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
    end

    actions do
      defaults([:read, :destroy, create: :*, update: :*])
    end
  end

  defmodule ExplicitPost do
    use Ash.Resource, domain: Domain, data_layer: AshMultiDatalayer.DataLayer

    multi_data_layer do
      orchestrator({AshMultiDatalayer.Orchestrator.ProvenCoverage, divergence_sampler: 0.05})
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

  describe "Info.orchestrator/1" do
    test "defaults to ProvenCoverage with the section aliases forwarded as opts" do
      assert {ProvenCoverage, opts} = Info.orchestrator(DefaultPost)
      assert Keyword.fetch!(opts, :divergence_sampler) == 0.0
      assert Keyword.fetch!(opts, :ledger_max_entries) == 10_000
      assert Keyword.fetch!(opts, :fold_aggregates?) == true
    end

    test "explicit orchestrator opts take precedence over forwarded alias defaults" do
      assert {ProvenCoverage, opts} = Info.orchestrator(ExplicitPost)
      assert Keyword.fetch!(opts, :divergence_sampler) == 0.05
      # unspecified aliases still forward their defaults
      assert Keyword.fetch!(opts, :ledger_max_entries) == 10_000
    end

    test "rerouted getters read from the resolved orchestrator opts" do
      # old section-alias form (DefaultPost) and new orchestrator-opts form
      # (ExplicitPost) both surface through the same getter.
      assert Info.divergence_sampler(DefaultPost) == 0.0
      assert Info.divergence_sampler(ExplicitPost) == 0.05
    end

    test "proven_coverage?/1 is true for the default strategy" do
      assert Info.proven_coverage?(DefaultPost)
      assert Info.proven_coverage?(ExplicitPost)
    end
  end

  describe "ProvenCoverage structural answers (boundary funnels)" do
    test "authority/1 is the read source of truth (last read layer)" do
      assert ProvenCoverage.authority(DefaultPost) ==
               List.last(Info.read_layer_modules(DefaultPost))
    end

    test "transaction_layer/1 is the authoritative write layer (first write layer)" do
      assert ProvenCoverage.transaction_layer(DefaultPost) ==
               hd(Info.write_layer_modules(DefaultPost))
    end

    test "can?/2 answers concretely (Phase 4a derivation)" do
      # read feature — read_order intersection (both Ets layers support :read).
      assert ProvenCoverage.can?(DefaultPost, :read) == true
      # bypass-guard — joins escape the coverage proof.
      assert ProvenCoverage.can?(DefaultPost, {:join, :inner}) == false
      # M3 refusal.
      assert ProvenCoverage.can?(DefaultPost, :aggregate_filter) == false
    end

    test "child_specs/1 is empty (lazy table owners)" do
      assert ProvenCoverage.child_specs([DefaultPost]) == []
    end
  end

  describe "shell delegates structural callbacks to the orchestrator" do
    test "source/1 resolves through authority/1" do
      # Ets has no source/1 → the shell tolerates it and returns "".
      assert AshMultiDatalayer.DataLayer.source(DefaultPost) == ""
    end

    test "can?/2 falls back to the shell's intersection semantics via :default" do
      assert AshMultiDatalayer.DataLayer.can?(DefaultPost, :read)
      assert AshMultiDatalayer.DataLayer.can?(DefaultPost, :create)
      refute AshMultiDatalayer.DataLayer.can?(DefaultPost, {:join, :inner})
    end
  end

  describe "ValidateOrchestrator verifier" do
    # Spark 2.7 surfaces verifier failures as compiler diagnostics, not runtime
    # raises (see VerifiersTest), so exercise the verifier directly on the DSL
    # config — the same idiom the sibling verifier tests use.
    test "rejects a module that does not implement the behaviour" do
      # Enum is a real, loadable module but implements none of the callbacks.
      module =
        define(
          quote do
            multi_data_layer do
              orchestrator(Enum)
              layer(:only, Ash.DataLayer.Ets)
              read_order([:only])
              write_order([:only])
            end
          end
        )

      assert error_message(
               AshMultiDatalayer.Verifiers.ValidateOrchestrator.verify(module.spark_dsl_config())
             ) =~ "does not implement the AshMultiDatalayer.Orchestrator"
    end

    test "accepts ProvenCoverage (the default)" do
      assert :ok =
               AshMultiDatalayer.Verifiers.ValidateOrchestrator.verify(
                 DefaultPost.spark_dsl_config()
               )
    end
  end

  # Mirrors VerifiersTest's helper: builds a resource at runtime so a verifier
  # diagnostic is a captured warning rather than a compile-time failure.
  defp define(body) do
    module = :"Elixir.AshMultiDatalayer.OrchestratorTest.R#{System.unique_integer([:positive])}"

    Module.create(
      module,
      quote do
        use Ash.Resource,
          domain: AshMultiDatalayer.OrchestratorTest.Domain,
          data_layer: AshMultiDatalayer.DataLayer

        unquote(body)

        attributes do
          uuid_primary_key(:id)
        end
      end,
      Macro.Env.location(__ENV__)
    )

    module
  end

  defp error_message({:error, %Spark.Error.DslError{message: message}}), do: message
  defp error_message(other), do: flunk("expected {:error, %DslError{}}, got: #{inspect(other)}")
end
