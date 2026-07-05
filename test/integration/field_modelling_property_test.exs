defmodule AshMultiDatalayer.Integration.FieldModellingPropertyTest do
  @moduledoc """
  Field-modelling property (fix-plan Phase 6.1): closes the review's "fields
  are not modelled at all" generator gap. For random filter/select/rows
  against the real ETS+Postgres stack:

    * a cold read and the identical warm repeat read return the same rows
      AND the same field values (C1);
    * a warm wider-select read of the same filter equals a cold read with
      that wider select (C1/C2);
    * the narrow -> wide -> narrow same-filter sequence ends covered — the
      third read is a coverage HIT, pinning the fingerprint-widening fix
      (review-2 F2) against a permanent miss loop;
    * a merged-read variant with a locally-evaluable calc whose input is
      outside the select is also field-complete (the second C1 shape).

  Each iteration touches Postgres, so `max_runs` is far lower than the pure
  in-memory solver properties (10k) — this is deliberately a slower, higher
  fidelity check of a narrower axis.
  """
  use AshMultiDatalayer.DataCase, async: false
  use ExUnitProperties

  @moduletag :property
  @moduletag timeout: 300_000

  alias AshMultiDatalayer.Test.Generators

  @runs 30

  defp reset_round! do
    AshMultiDatalayer.TestSupport.reset!(TestPost)
    Ash.DataLayer.Ets.stop(TestPost)

    MirrorPost
    |> Ash.read!()
    |> Enum.each(&Ash.destroy!/1)
  end

  defp seed_rows!(rows) do
    Enum.map(rows, fn row ->
      MirrorPost
      |> Ash.Changeset.for_create(:create, %{
        name: row.name,
        age: row.age,
        published_at: row.published_at
      })
      |> Ash.create!()
    end)
  end

  defp field_tuple(row, fields), do: Map.new(fields, &{&1, Map.get(row, &1)})
  defp by_id(rows), do: Map.new(rows, &{&1.id, &1})

  property "cold read, warm repeat read, and a wider warm read all agree on field values" do
    check all(
            filter <- Generators.filter(),
            select <- Generators.select_subset(),
            rows <- StreamData.list_of(Generators.row(), length: 5),
            max_runs: @runs
          ) do
      reset_round!()
      seed_rows!(rows)

      normalised = AshMultiDatalayer.Coverage.Normaliser.normalise(filter, TestPost)

      unless normalised.opaque? do
        narrow_query =
          TestPost |> Ash.Query.do_filter(filter) |> Ash.Query.select(select)

        cold = Ash.read!(narrow_query) |> by_id()
        warm = Ash.read!(narrow_query) |> by_id()

        assert Map.keys(cold) |> Enum.sort() == Map.keys(warm) |> Enum.sort(),
               "warm repeat read returned different rows than the cold read"

        for {id, cold_row} <- cold do
          warm_row = Map.fetch!(warm, id)

          assert field_tuple(cold_row, select) == field_tuple(warm_row, select),
                 "warm hit served different field values than the cold miss for #{inspect(select)}"
        end

        # A warm WIDER (full) read of the same filter must equal a cold full
        # read of that filter — the entry's narrower loaded_fields must not
        # leak stale/nil values into fields it never demanded.
        wide_query = TestPost |> Ash.Query.do_filter(filter)
        wide_warm = Ash.read!(wide_query) |> by_id()

        AshMultiDatalayer.disable!(TestPost)

        wide_cold =
          try do
            Ash.read!(wide_query) |> by_id()
          after
            AshMultiDatalayer.enable!(TestPost)
          end

        all_fields = [:id, :name, :age, :score, :published_at]

        assert Map.keys(wide_warm) |> Enum.sort() == Map.keys(wide_cold) |> Enum.sort(),
               "wide warm read returned different rows than a direct source read"

        for {id, warm_row} <- wide_warm do
          source_row = Map.fetch!(wide_cold, id)

          assert field_tuple(warm_row, all_fields) == field_tuple(source_row, all_fields),
                 "wide warm read served different field values than the source of truth"
        end

        # narrow -> wide -> narrow: the third (narrow) read must now be a
        # coverage HIT — the fingerprint-widening entry now covers it,
        # never re-missing on :fields_insufficient (review-2 F2).
        parent = self()
        handler = "field-modelling-#{System.unique_integer([:positive])}"

        :telemetry.attach(
          handler,
          [:ash_multi_datalayer, :read, :hit],
          fn _event, _measurements, _metadata, _config -> send(parent, :mdl_hit) end,
          nil
        )

        try do
          Ash.read!(narrow_query)
          assert_received :mdl_hit, "the narrow->wide->narrow sequence did not end covered"
        after
          :telemetry.detach(handler)
        end
      end
    end
  end

  property "a merged read's local calc sees fields outside the select" do
    check all(
            rows <- StreamData.list_of(Generators.row(), length: 3),
            max_runs: @runs
          ) do
      reset_round!()
      seed_rows!(rows)

      query =
        TestPost
        |> Ash.Query.select([:id, :name])
        |> Ash.Query.load(:adult?)

      cold = Ash.read!(query) |> by_id()
      warm = Ash.read!(query) |> by_id()

      assert Map.keys(cold) |> Enum.sort() == Map.keys(warm) |> Enum.sort()

      for {id, cold_row} <- cold do
        warm_row = Map.fetch!(warm, id)

        assert cold_row.adult? == warm_row.adult?,
               "the merged read's local calc disagreed between cold and warm " <>
                 "(age is outside the query's own select): #{inspect(cold_row.adult?)} vs " <>
                 "#{inspect(warm_row.adult?)}"
      end
    end
  end
end
