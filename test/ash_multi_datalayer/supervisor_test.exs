defmodule AshMultiDatalayer.SupervisorTest do
  use ExUnit.Case, async: true

  alias AshMultiDatalayer.Test.LocalOutbox.Widget

  defmodule PlainEtsResource do
    @moduledoc false
    use Ash.Resource, domain: __MODULE__.Domain, data_layer: Ash.DataLayer.Ets

    ets do
      private?(true)
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read, :destroy, create: :*, update: :*])
    end

    defmodule Domain do
      @moduledoc false
      use Ash.Domain, validate_config_inclusion?: false

      resources do
        resource AshMultiDatalayer.SupervisorTest.PlainEtsResource
      end
    end
  end

  # L12 item 4: an explicit `resources:` list wasn't filtered by
  # `multi_datalayer?/1` — a plain (non-MDL) resource mixed in would reach
  # `Info.orchestrator/1`, which reads MDL-specific DSL metadata that isn't
  # there, before any orchestrator-grouping logic ever gets a chance to
  # ignore it.
  test "a plain, non-MDL resource in an explicit resources: list is filtered out, not crashed on" do
    assert {:ok, {_flags, child_specs}} =
             AshMultiDatalayer.Supervisor.init(resources: [PlainEtsResource, Widget])

    # The base TableSupervisor child, plus whatever Widget's LocalOutbox
    # orchestrator contributes (a Sweeper + Api.child_specs) — nothing
    # attributable to PlainEtsResource, and no crash reaching this far.
    assert Enum.any?(child_specs, &match?(%{id: AshMultiDatalayer.TableSupervisor}, &1))

    assert Enum.any?(child_specs, fn
             %{id: {AshMultiDatalayer.Orchestrator.LocalOutbox.Sweeper, _}} -> true
             _ -> false
           end)
  end

  test "an explicit resources: list of only non-MDL resources contributes no orchestrator children" do
    assert {:ok, {_flags, child_specs}} =
             AshMultiDatalayer.Supervisor.init(resources: [PlainEtsResource])

    assert [%{id: AshMultiDatalayer.TableSupervisor}] = child_specs
  end
end
