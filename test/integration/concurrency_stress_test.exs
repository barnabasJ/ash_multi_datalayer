defmodule AshMultiDatalayer.Integration.ConcurrencyStressTest do
  @moduledoc """
  Concurrency stress test (fix-plan Phase 6.2/6.4): writer + reader tasks
  hammering `FailingPost` (ETS cache over counted Postgres, with a
  propagation-failure knob) concurrently, mixing local `WriteDispatch`
  writes with external-invalidation shapes (C4's `on_write/4` called
  directly, as an out-of-band notification source would). At quiescence,
  every recorded coverage entry's filter re-run against the cache must
  equal the source — invariants 2 (invalidation is final) and 3 (covered
  region implies fresh rows) in executable form, reusing the same
  PK-set-comparison shape as `AshMultiDatalayer.Divergence`.

  Also reports the cache hit rate under write load: Phase 3's epoch guard
  trades hit rate for freshness under sustained write concurrency, and the
  fix plan requires that cost be a measured number, not a surprise.
  """
  use AshMultiDatalayer.DataCase, async: false

  require Ash.Query

  alias AshMultiDatalayer.Coverage
  alias AshMultiDatalayer.Coverage.Invalidation
  alias AshMultiDatalayer.Delegate
  alias AshMultiDatalayer.Test.CountingPostgres
  alias AshMultiDatalayer.Test.FailingEts
  alias AshMultiDatalayer.Test.Resources.FailingPost

  @writers 4
  @readers 4
  @ops_per_writer 40
  @ops_per_reader 60
  @pool_size 12

  setup do
    FailingEts.clear!()
    on_exit(fn -> FailingEts.clear!() end)
    :ok
  end

  defp as_failing_post(%MirrorPost{} = m) do
    struct(FailingPost, Map.take(m, [:id, :name, :age, :score, :published_at]))
  end

  defp seed_pool! do
    slots = :ets.new(:stress_slots, [:set, :public])

    for slot <- 1..@pool_size do
      row =
        FailingPost
        |> Ash.Changeset.for_create(:create, %{name: "row#{slot}", age: Enum.random(0..100)})
        |> Ash.create!()

      :ets.insert(slots, {slot, row.id})
    end

    slots
  end

  defp random_slot_id(slots), do: :ets.lookup_element(slots, Enum.random(1..@pool_size), 2)

  defp put_slot(slots, id), do: :ets.insert(slots, {Enum.random(1..@pool_size), id})

  # --- writer op shapes ------------------------------------------------

  defp writer_op(slots) do
    case Enum.random([:local_update, :local_destroy_recreate, :external_update, :toggle_failure]) do
      :local_update ->
        with_row(slots, fn record ->
          record
          |> Ash.Changeset.for_update(:update, %{age: Enum.random(0..100)})
          |> Ash.update!()
        end)

      :local_destroy_recreate ->
        with_row(slots, fn record ->
          Ash.destroy!(record)

          fresh =
            FailingPost
            |> Ash.Changeset.for_create(:create, %{name: record.name, age: Enum.random(0..100)})
            |> Ash.create!()

          put_slot(slots, fresh.id)
        end)

      :external_update ->
        # The C4 shape: a write outside FailingPost's own WriteDispatch
        # (through MirrorPost, sharing the table), invalidated by calling
        # on_write/4 directly — exactly what an external notification
        # source is documented to do.
        with_mirror_row(slots, fn mirror ->
          row_before = as_failing_post(mirror)

          updated =
            mirror
            |> Ash.Changeset.for_update(:update, %{age: Enum.random(0..100)})
            |> Ash.update!()

          Invalidation.on_write(FailingPost, nil, row_before, as_failing_post(updated))
        end)

      :toggle_failure ->
        if Enum.random([true, false]) do
          FailingEts.fail_rate!(Enum.random([:upsert, :destroy]), 0.3)
        else
          FailingEts.clear!()
        end
    end
  end

  defp with_row(slots, fun) do
    id = random_slot_id(slots)

    case Ash.get(FailingPost, id) do
      {:ok, record} -> fun.(record)
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp with_mirror_row(slots, fun) do
    id = random_slot_id(slots)

    case Ash.get(MirrorPost, id) do
      {:ok, record} -> fun.(record)
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp reader_op do
    query =
      case Enum.random([:age_gt, :age_lt, :name_eq, :unfiltered]) do
        :age_gt -> FailingPost |> Ash.Query.filter(age > ^Enum.random(0..100))
        :age_lt -> FailingPost |> Ash.Query.filter(age < ^Enum.random(0..100))
        :name_eq -> FailingPost |> Ash.Query.filter(name == ^"row#{Enum.random(1..12)}")
        :unfiltered -> FailingPost
      end

    Ash.read(query)
  rescue
    _ -> :ok
  end

  test "quiescence: every recorded entry's cache filter equals the source, and hit rate is reported" do
    slots = seed_pool!()

    parent = self()
    handler = "stress-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [
        [:ash_multi_datalayer, :read, :hit],
        [:ash_multi_datalayer, :read, :partial],
        [:ash_multi_datalayer, :read, :miss]
      ],
      fn event, _measurements, _metadata, _config ->
        send(parent, {:mdl_read, List.last(event)})
      end,
      nil
    )

    writer_tasks =
      for _ <- 1..@writers do
        Task.async(fn ->
          for _ <- 1..@ops_per_writer, do: writer_op(slots)
        end)
      end

    reader_tasks =
      for _ <- 1..@readers do
        Task.async(fn ->
          for _ <- 1..@ops_per_reader, do: reader_op()
        end)
      end

    Task.await_many(writer_tasks, 30_000)
    Task.await_many(reader_tasks, 30_000)
    :telemetry.detach(handler)

    # Never leave a failure knob engaged after the mix finishes.
    FailingEts.clear!()

    counts = drain_read_counts()
    total_reads = counts |> Map.values() |> Enum.sum()
    hits = Map.get(counts, :hit, 0) + Map.get(counts, :partial, 0)
    hit_rate = if total_reads > 0, do: hits / total_reads, else: 0.0

    IO.puts(
      "\n[concurrency stress] reads=#{total_reads} hit=#{Map.get(counts, :hit, 0)} " <>
        "partial=#{Map.get(counts, :partial, 0)} miss=#{Map.get(counts, :miss, 0)} " <>
        "hit_rate=#{Float.round(hit_rate, 3)} (under sustained write concurrency — " <>
        "Phase 3's epoch guard trades hit rate for freshness, per NFR2)"
    )

    assert total_reads > 0
    assert hit_rate >= 0.0 and hit_rate <= 1.0

    assert_quiescence!()
  end

  defp drain_read_counts(acc \\ %{}) do
    receive do
      {:mdl_read, kind} -> drain_read_counts(Map.update(acc, kind, 1, &(&1 + 1)))
    after
      0 -> acc
    end
  end

  # Invariant 2+3 in executable form: for every surviving ledger entry, the
  # cache layer's rows under its filter (restricted to its own
  # loaded_fields) must equal the source's rows under the same filter —
  # exactly the PK-set comparison AshMultiDatalayer.Divergence already
  # makes for shadow sampling, reused here as the quiescence check.
  defp assert_quiescence! do
    [pk] = Ash.Resource.Info.primary_key(FailingPost)
    cache_layer = FailingEts
    source_layer = CountingPostgres

    for entry <- Coverage.entries(FailingPost, nil) do
      query = %AshMultiDatalayer.DataLayer.Query{
        resource: FailingPost,
        domain: Ash.Resource.Info.domain(FailingPost),
        filter: entry.filter,
        select: [pk]
      }

      {:ok, cache_rows} = Delegate.run_on_layer(query, cache_layer)
      {:ok, source_rows} = Delegate.run_on_layer(query, source_layer)

      cache_pks = MapSet.new(cache_rows, &Map.fetch!(&1, pk))
      source_pks = MapSet.new(source_rows, &Map.fetch!(&1, pk))

      assert MapSet.equal?(cache_pks, source_pks),
             "entry #{inspect(entry.filter)} diverged: cache=#{inspect(cache_pks)} " <>
               "source=#{inspect(source_pks)}"
    end
  end
end
