defmodule AshMultiDatalayer.Divergence do
  @moduledoc """
  Shadow-read sampling: a configurable fraction of coverage-hit reads are
  additionally re-run against the last read layer, and the two primary-key
  sets compared. A mismatch emits
  `[:ash_multi_datalayer, :read, :divergence_detected]` — the production
  canary for solver/invalidation bugs and (with a remote source of truth)
  out-of-band writes the client never saw.

  Sampling never changes caller-visible behaviour: the cached rows are
  returned regardless, and a failing shadow read is silent. Off by default
  (`divergence_sampler 0.0`) — each sampled hit costs one extra query
  against the source of truth.
  """

  alias AshMultiDatalayer.DataLayer.Info
  alias AshMultiDatalayer.Delegate
  alias AshMultiDatalayer.Telemetry

  @doc """
  Possibly shadow-checks a coverage hit. Returns `:ok` always.
  """
  @spec maybe_sample(struct(), module(), [Ash.Resource.record()]) :: :ok
  def maybe_sample(query, resource, cached_records) do
    rate = Info.divergence_sampler(resource)

    if sample?(rate) do
      shadow_check(query, resource, cached_records)
    end

    :ok
  end

  defp sample?(rate) when is_float(rate) and rate > 0.0, do: :rand.uniform() < rate
  defp sample?(_rate), do: false

  defp shadow_check(query, resource, cached_records) do
    source_layer = List.last(Info.read_layer_modules(resource))

    case Delegate.run_on_layer(query, source_layer) do
      {:ok, primary_records} ->
        compare(query, resource, cached_records, primary_records)

      {:error, _reason} ->
        # The shadow read is best-effort; a failure must not affect the read.
        :ok
    end
  end

  defp compare(query, resource, cached_records, primary_records) do
    primary_key = Ash.Resource.Info.primary_key(resource)

    cache_keys = MapSet.new(cached_records, &Map.take(&1, primary_key))
    primary_keys = MapSet.new(primary_records, &Map.take(&1, primary_key))

    unless MapSet.equal?(cache_keys, primary_keys) do
      Telemetry.read(
        :divergence_detected,
        resource,
        query,
        %{
          cache_count: MapSet.size(cache_keys),
          primary_count: MapSet.size(primary_keys)
        },
        %{
          pk_delta: %{
            only_in_cache: MapSet.difference(cache_keys, primary_keys) |> Enum.to_list(),
            only_in_primary: MapSet.difference(primary_keys, cache_keys) |> Enum.to_list()
          }
        }
      )
    end

    :ok
  end
end
