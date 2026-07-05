defmodule AshMultiDatalayer.Orchestrator.LocalOutbox.Snapshot do
  @moduledoc """
  Dumps a record's attributes to a JSON-safe `:map` (the outbox `payload` /
  `base_image` encoding — plan Phase 2 item 10) and rebuilds a record struct from
  one, so the flush worker can re-apply the exact state the local layer returned
  to a replication target (never a re-run of the caller's changeset — same
  rationale as FR3.6).

  Each attribute is dumped through its Ash type's embedded form (`dump_to_embedded`,
  the inverse of `cast_input`), so `DateTime`/`Decimal`/etc. survive the SQLite
  JSON round-trip. Keys are strings (JSON), matching how they read back.
  """

  @doc "Dump a record's loaded attributes to a JSON-safe string-keyed map."
  @spec dump(Ash.Resource.t(), Ash.Resource.record()) :: map()
  def dump(resource, record) do
    for attribute <- Ash.Resource.Info.attributes(resource),
        loaded?(value = Map.get(record, attribute.name)),
        into: %{} do
      {:ok, dumped} = Ash.Type.dump_to_embedded(attribute.type, value, attribute.constraints)
      {to_string(attribute.name), dumped}
    end
  end

  @doc "Rebuild a record struct from a dumped map (the inverse of `dump/2`)."
  @spec load(Ash.Resource.t(), map()) :: Ash.Resource.record()
  def load(resource, map) when is_map(map) do
    attrs =
      for attribute <- Ash.Resource.Info.attributes(resource),
          Map.has_key?(map, to_string(attribute.name)) do
        {:ok, value} =
          Ash.Type.cast_input(
            attribute.type,
            map[to_string(attribute.name)],
            attribute.constraints
          )

        {attribute.name, value}
      end

    struct(resource, Map.new(attrs))
  end

  @doc "The primary-key map (string keys, JSON-safe) for a record."
  @spec record_pk(Ash.Resource.t(), Ash.Resource.record()) :: map()
  def record_pk(resource, record) do
    for key <- Ash.Resource.Info.primary_key(resource), into: %{} do
      attribute = Ash.Resource.Info.attribute(resource, key)

      {:ok, dumped} =
        Ash.Type.dump_to_embedded(attribute.type, Map.get(record, key), attribute.constraints)

      {to_string(key), dumped}
    end
  end

  defp loaded?(%Ash.NotLoaded{}), do: false
  defp loaded?(_), do: true
end
