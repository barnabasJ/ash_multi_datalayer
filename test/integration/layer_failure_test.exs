defmodule AshMultiDatalayer.Integration.LayerFailureTest do
  use AshMultiDatalayer.DataCase, async: false

  require Ash.Query

  alias AshMultiDatalayer.Test.CountingPostgres
  alias AshMultiDatalayer.Test.FailingEts
  alias AshMultiDatalayer.Test.Resources.FailingPost

  defp pg_reads, do: CountingLayer.count(CountingPostgres, :run_query)

  setup do
    FailingEts.clear!()
    reset_resource!(FailingPost)
    CountingLayer.reset!()

    telemetry_ref = "layer-failure-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      telemetry_ref,
      [:ash_multi_datalayer, :write, :failed_at_layer],
      fn event, measurements, metadata, _config ->
        send(parent, {:mdl, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      FailingEts.clear!()
      :telemetry.detach(telemetry_ref)
    end)

    :ok
  end

  test "invalidate-before-propagate: a failed cache upsert degrades to a miss, never staleness" do
    record =
      FailingPost
      |> Ash.Changeset.for_create(:create, %{name: "foo", age: 20})
      |> Ash.create!()

    # Warm coverage so the stale-read hazard exists.
    assert [%{age: 20}] = FailingPost |> Ash.Query.filter(name == "foo") |> Ash.read!()
    warm_reads = pg_reads()

    # Rig the cache layer to fail its upsert, then write.
    FailingEts.fail!(:upsert)

    updated =
      record
      |> Ash.Changeset.for_update(:update, %{age: 21})
      |> Ash.update!()

    # The operation SUCCEEDED (authoritative committed)...
    assert updated.age == 21
    # ...and the failure was surfaced via telemetry.
    assert_receive {:mdl, [_, :write, :failed_at_layer], _, %{layer: FailingEts}}

    # The critical assertion: the next read is a fall-through returning the
    # NEW value — never the stale cached 20.
    FailingEts.clear!()
    assert [%{age: 21}] = FailingPost |> Ash.Query.filter(name == "foo") |> Ash.read!()
    assert pg_reads() == warm_reads + 1
  end

  test "authoritative failure aborts everything: no invalidation, no propagation" do
    record =
      FailingPost
      |> Ash.Changeset.for_create(:create, %{name: "foo", age: 20})
      |> Ash.create!()

    FailingPost |> Ash.Query.filter(name == "foo") |> Ash.read!()
    assert [_] = AshMultiDatalayer.Coverage.entries(FailingPost, nil)

    # Make the authoritative write fail (invalid data type via raw changeset
    # is hard to rig; instead terminate the sandbox transaction path by
    # violating a constraint: none exist, so rig via a bogus update through
    # the data layer directly).
    changeset =
      record
      |> Ash.Changeset.for_update(:update, %{age: 21})
      |> Map.put(:data, %{record | id: "not-a-uuid"})

    assert {:error, _} = AshMultiDatalayer.WriteDispatch.update(FailingPost, changeset)

    # Coverage survives an authoritative failure (nothing changed anywhere).
    assert [_] = AshMultiDatalayer.Coverage.entries(FailingPost, nil)
  end

  test "a failed cache destroy also degrades to a miss" do
    record =
      FailingPost
      |> Ash.Changeset.for_create(:create, %{name: "gone", age: 1})
      |> Ash.create!()

    FailingPost |> Ash.Query.filter(name == "gone") |> Ash.read!()

    FailingEts.fail!(:destroy)
    :ok = Ash.destroy!(record)
    assert_receive {:mdl, [_, :write, :failed_at_layer], _, %{operation: :destroy}}

    FailingEts.clear!()

    # Fall-through: the source of truth no longer has the row.
    assert [] = FailingPost |> Ash.Query.filter(name == "gone") |> Ash.read!()
  end
end
