defmodule AshMultiDatalayer.Integration.DivergenceSamplerTest do
  use AshMultiDatalayer.DataCase, async: false

  require Ash.Query

  alias AshMultiDatalayer.Test.Resources.SampledPost

  setup do
    parent = self()
    handler = "divergence-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:ash_multi_datalayer, :read, :divergence_detected],
      fn event, measurements, metadata, _ ->
        send(parent, {:mdl, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  test "an out-of-band write is detected by a sampled cache hit" do
    SampledPost
    |> Ash.Changeset.for_create(:create, %{name: "watched", age: 1})
    |> Ash.create!()

    # Warm coverage through the sampled resource.
    SampledPost |> Ash.Query.filter(name == "watched") |> Ash.read!()

    # Mutate the source of truth BEHIND the client's back (MirrorPost writes
    # straight to Postgres; the multi datalayer never sees it).
    MirrorPost
    |> Ash.Changeset.for_create(:create, %{name: "watched", age: 2})
    |> Ash.create!()

    # The next read is a stale cache hit; the 1.0 sampler shadow-reads the
    # primary and detects the extra row.
    cached = SampledPost |> Ash.Query.filter(name == "watched") |> Ash.read!()
    assert length(cached) == 1

    assert_receive {:mdl, [_, :read, :divergence_detected], %{cache_count: 1, primary_count: 2},
                    %{pk_delta: %{only_in_cache: [], only_in_primary: [_]}}}
  end

  test "matching cache and primary emit nothing" do
    SampledPost
    |> Ash.Changeset.for_create(:create, %{name: "calm", age: 1})
    |> Ash.create!()

    SampledPost |> Ash.Query.filter(name == "calm") |> Ash.read!()
    SampledPost |> Ash.Query.filter(name == "calm") |> Ash.read!()

    refute_receive {:mdl, [_, :read, :divergence_detected], _, _}, 50
  end

  test "rate 0.0 (the default) never samples" do
    TestPost
    |> Ash.Changeset.for_create(:create, %{name: "quiet", age: 1})
    |> Ash.create!()

    TestPost |> Ash.Query.filter(name == "quiet") |> Ash.read!()

    MirrorPost
    |> Ash.Changeset.for_create(:create, %{name: "quiet", age: 2})
    |> Ash.create!()

    # Stale hit, but no sampler -> no event (and, by design, stale data:
    # out-of-band writes are exactly what the sampler exists to surface).
    TestPost |> Ash.Query.filter(name == "quiet") |> Ash.read!()

    refute_receive {:mdl, [_, :read, :divergence_detected], _, _}, 50
  end
end
