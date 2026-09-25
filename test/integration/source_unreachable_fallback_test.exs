defmodule AshMultiDatalayer.Integration.SourceUnreachableFallbackTest do
  use AshMultiDatalayer.DataCase, async: false

  require Ash.Query

  alias AshMultiDatalayer.Coverage
  alias AshMultiDatalayer.Test.FailableCountingPostgres
  alias AshMultiDatalayer.Test.FailableLayer
  alias AshMultiDatalayer.Test.Resources.SourceFailablePost

  setup_all do
    FailableLayer.ensure_table!()
    :ok
  end

  setup do
    on_exit(fn -> FailableLayer.clear_reads(FailableCountingPostgres) end)

    telemetry_ref = make_ref()
    parent = self()

    :telemetry.attach_many(
      "source-unreachable-fallback-test-#{inspect(telemetry_ref)}",
      [
        [:ash_multi_datalayer, :read, :degraded],
        [:ash_multi_datalayer, :read, :miss]
      ],
      fn event, measurements, metadata, _config ->
        send(parent, {:mdl, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("source-unreachable-fallback-test-#{inspect(telemetry_ref)}") end)

    post =
      SourceFailablePost
      |> Ash.Changeset.for_create(:create, %{name: "foo", age: 20})
      |> Ash.create!()

    # Simulate a coverage ledger dropped by `LifecycleGuard`'s
    # missed-notification/resubscribe reconcile — the cache (l1) still
    # physically holds the row the create above just wrote there, but
    # nothing is recorded as covered anymore.
    Coverage.reset(SourceFailablePost)

    %{post: post}
  end

  test "a coverage miss whose source read is unreachable falls back to the cache", %{post: post} do
    FailableLayer.fail_reads(FailableCountingPostgres, {:transient, "offline"})

    assert [%{id: id, name: "foo"} = record] =
             SourceFailablePost
             |> Ash.Query.filter(id == ^post.id)
             |> Ash.read!()

    assert id == post.id
    # A caller tracking sync/freshness (e.g. a "last synced" label) must be
    # able to tell this apart from a confirmed answer — see this fix's own
    # note in `source_unreachable_fallback/6`.
    assert record.__metadata__[:amd_degraded_read] == true
    assert_receive {:mdl, [_, :read, :degraded], _, %{source_error: _}}
    refute_receive {:mdl, [_, :read, :miss], _, _}
  end

  test "a real rejection from the source is not masked by a stale cache read" do
    FailableLayer.fail_reads(FailableCountingPostgres, %Ash.Error.Forbidden{})

    assert {:error, %Ash.Error.Forbidden{}} =
             SourceFailablePost
             |> Ash.Query.filter(name == "foo")
             |> Ash.read()
  end
end
