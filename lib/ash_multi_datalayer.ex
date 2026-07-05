defmodule AshMultiDatalayer do
  @moduledoc """
  Generic ordered layered data layers for Ash resources.

  `ash_multi_datalayer` lets a resource route reads and writes across multiple
  underlying `Ash.DataLayer`s — most commonly an in-process ETS cache in front
  of a source of truth (Postgres, a remote Ash backend via `ash_remote`, …).

  See `AshMultiDatalayer.DataLayer` for the resource DSL, and the guides for
  layering recipes, operations, and telemetry.
  """

  @doc """
  Disables layered behaviour for a resource at runtime: reads route to the
  last layer in `read_order`, writes to the first layer in `write_order`
  (both the source of truth), skipping cache layers and coverage entirely.
  """
  defdelegate disable!(resource), to: AshMultiDatalayer.KillSwitch

  @doc "Re-enables layered behaviour for a resource. See `disable!/1`."
  defdelegate enable!(resource), to: AshMultiDatalayer.KillSwitch

  @doc "Whether layered behaviour is currently enabled for the resource."
  defdelegate enabled?(resource), to: AshMultiDatalayer.KillSwitch

  @doc """
  Purges a row this library's cache still believes exists, given independent
  proof it doesn't — for consumers that discover staleness out-of-band (the
  lost-notification case: an external invalidation source, e.g. an
  `ash_remote` realtime bridge, is documented as at-most-once with no
  replay, so a push can simply be dropped with nothing to react to).

  Reuses `AshMultiDatalayer.Coverage.Invalidation.on_write/4` wholesale:
  `forget!/3` is exactly `on_write(resource, tenant, record, nil)` in a
  public wrapper — epoch bump, ledger-entry drops, and physical eviction
  from every earlier read layer — keeping `on_write/4` the single upholder
  of the physical invariant (C4) rather than a parallel implementation.

  `pk_or_record` is either a full loaded record (used as-is) or a plain map
  of just the primary key (e.g. `%{id: id}`). A PK-only call builds the
  probe record with every **non-PK attribute set to `%Ash.NotLoaded{}`,
  never `nil`**: under Ash's runtime nil semantics a comparison like
  `age > 5` against `age: nil` is a definite non-match, so a nil-built
  probe would let an entry that actually covers the row's true state
  survive the drop while the physical row underneath it is evicted —
  silently losing the row on the next covered read. `NotLoaded` degrades
  filter evaluation to `:unknown`, which `Invalidation.should_drop?/3`
  treats as a conservative match.

  Options: `:tenant` (defaults to `nil`, the tenantless partition).
  """
  @spec forget!(module(), Ash.Resource.Record.t() | map(), keyword()) :: :ok
  def forget!(resource, pk_or_record, opts \\ []) do
    tenant = opts[:tenant]
    row_before = AshMultiDatalayer.forget_probe(resource, pk_or_record)
    AshMultiDatalayer.Coverage.Invalidation.on_write(resource, tenant, row_before, nil)
    :ok
  end

  @doc false
  def forget_probe(resource, %resource{} = record), do: record

  def forget_probe(resource, pk) when is_map(pk) do
    primary_key = Ash.Resource.Info.primary_key(resource)
    pk = Map.new(pk, fn {key, value} -> {to_attribute_name(key), value} end)

    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.reduce(struct(resource), fn attribute, probe ->
      if attribute.name in primary_key do
        Map.put(probe, attribute.name, Map.get(pk, attribute.name))
      else
        Map.put(probe, attribute.name, %Ash.NotLoaded{
          field: attribute.name,
          type: :attribute,
          resource: resource
        })
      end
    end)
  end

  defp to_attribute_name(key) when is_atom(key), do: key
  defp to_attribute_name(key) when is_binary(key), do: String.to_existing_atom(key)

  @doc """
  Whether `error` (as raised/returned by a failed Ash call) is, anywhere in
  it, an `Ash.Error.Query.NotFound` — the signal `forget!/3` is meant to
  react to. Handles a bare error, `Ash.Error.Invalid`'s wrapped list, and a
  plain list of errors; never raises.
  """
  @spec not_found?(term()) :: boolean()
  def not_found?(%Ash.Error.Query.NotFound{}), do: true
  def not_found?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &not_found?/1)
  def not_found?(errors) when is_list(errors), do: Enum.any?(errors, &not_found?/1)
  def not_found?(_other), do: false
end
