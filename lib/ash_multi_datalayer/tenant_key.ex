defmodule AshMultiDatalayer.TenantKey do
  @moduledoc """
  The tenant model has three distinct concepts (see the second-review-fixes
  index's binding decision) — do not collapse them:

    1. **Canonical partition key** (`canonical/2`) — the ONE shared string
       every bucketing path (read coverage, write invalidation, outbox chain
       filters, notifications) must agree on. Integer/atom tenant values
       become strings via `to_string/1` (never `inspect/1`); `nil` becomes
       the single unscoped sentinel (`unscoped/0`) — never `nil` itself.
    2. **Unscoped scope sentinel** (`unscoped/0`) — reconciles the ledger's
       former `:__global__` with the LocalOutbox scan-scope marker into ONE
       value. A scope marker, not a tenant.
    3. **Target-call tenant value** (`query/2`, `changeset/3`, `record/3`) —
       the real tenant a *target* data layer's Ash calls understand (via
       `Ash.ToTenant`/`set_tenant`). Never the partition string, never the
       sentinel. Consumers needing the partition key must explicitly call
       `canonical/2` on this — these functions never do it themselves,
       because the same raw value also has to survive intact for target
       calls (e.g. `write_through`'s push to replica targets).
  """

  alias AshMultiDatalayer.Coverage.Normaliser

  @unscoped :__global__

  @doc "The single unscoped/scan-all sentinel (concept 2) — never `nil`."
  @spec unscoped() :: :__global__
  def unscoped, do: @unscoped

  @doc "Whether `tenant` is the unscoped sentinel (or `nil`, its scan-time equivalent)."
  @spec unscoped?(term()) :: boolean()
  def unscoped?(tenant), do: tenant in [nil, @unscoped]

  @doc """
  Translates the unscoped scan sentinel back to Ash's own "no tenant" (`nil`)
  for target-layer calls (concept 3) — a caller that asked LocalOutbox to
  scan every partition (H5) must never pass that scan marker on to a
  `Target`/backfill Ash call, which would try to read/write a literal
  tenant named `:__global__`. Any other value (including `nil` itself)
  passes through unchanged.
  """
  @spec real(term()) :: term()
  def real(tenant), do: if(tenant == @unscoped, do: nil, else: tenant)

  @doc """
  The canonical partition-key string (concept 1) for ANY tenant
  representation — a struct (via `Ash.ToTenant`), an integer/atom/uuid
  attribute value, or an already-canonical string. `nil` canonicalizes to
  the single unscoped sentinel (`unscoped/0`), never to `nil` itself.

  This is NOT a real tenant value — never pass it to a target layer's Ash
  calls (see the moduledoc's concept 3).
  """
  @spec canonical(Ash.Resource.t(), term()) :: String.t() | :__global__
  def canonical(_resource, nil), do: @unscoped
  def canonical(_resource, @unscoped), do: @unscoped

  def canonical(resource, tenant) do
    case Ash.ToTenant.to_tenant(tenant, resource) do
      nil -> @unscoped
      value when is_binary(value) -> value
      value -> to_string(value)
    end
  end

  @doc "Returns the real tenant value for a read query's target-layer calls (concept 3)."
  def query(resource, %{tenant: tenant, filter: filter}) do
    case Ash.Resource.Info.multitenancy_strategy(resource) do
      :attribute -> tenant || tenant_from_filter(resource, filter)
      _ -> tenant
    end
  end

  @doc "Returns the real tenant value for a write changeset/result (concept 3)."
  def changeset(resource, changeset, record \\ nil) do
    case Ash.Resource.Info.multitenancy_strategy(resource) do
      :context -> changeset.to_tenant || to_tenant(resource, changeset.tenant)
      :attribute -> attribute_value(resource, record) || attribute_value(resource, changeset)
      _ -> nil
    end
  end

  @doc "Returns the real tenant value for a record, falling back when needed (concept 3)."
  def record(resource, record, fallback \\ nil) do
    case Ash.Resource.Info.multitenancy_strategy(resource) do
      :attribute -> attribute_value(resource, record) || fallback
      :context -> metadata_tenant(record) || fallback
      _ -> fallback
    end
  end

  defp to_tenant(_resource, nil), do: nil
  defp to_tenant(resource, tenant), do: Ash.ToTenant.to_tenant(tenant, resource)

  defp attribute_value(_resource, nil), do: nil

  # L3: a create's `changeset.data` never carries the attribute (it's set
  # only in `changeset.attributes` until the write lands) — reading the
  # changeset struct's own top-level keys (which `Map.get/2` on `%Ash.
  # Changeset{}` would do) always misses, since resource attributes are not
  # struct fields of `Ash.Changeset`.
  defp attribute_value(resource, %Ash.Changeset{} = changeset) do
    with attr when not is_nil(attr) <- Ash.Resource.Info.multitenancy_attribute(resource) do
      Map.get(changeset.attributes, attr)
    end
  end

  defp attribute_value(resource, record) do
    with attr when not is_nil(attr) <- Ash.Resource.Info.multitenancy_attribute(resource) do
      Map.get(record, attr)
    end
  end

  defp metadata_tenant(%{__metadata__: metadata}) when is_map(metadata), do: metadata[:tenant]
  defp metadata_tenant(_), do: nil

  # B3: a structural walk of the filter AST (via the same DNF normaliser the
  # coverage ledger already uses), not a regex over `inspect/1` output —
  # exact attribute identity (no `org` vs `organization_id` collision), no
  # string-vs-typed mismatch, and it naturally covers zero-row reads (it
  # never looks at returned rows). Conservative: any shape the normaliser
  # can't prove (opaque, multiple disjuncts disagreeing, a range/not_eq/`in`
  # on the attribute) returns `nil` rather than risk the wrong partition.
  defp tenant_from_filter(resource, filter) do
    attr = Ash.Resource.Info.multitenancy_attribute(resource)
    if attr, do: filter |> Normaliser.normalise(resource) |> single_eq_value(attr)
  end

  defp single_eq_value(%Normaliser.Normalised{opaque?: true}, _attr), do: nil
  defp single_eq_value(%Normaliser.Normalised{disjuncts: []}, _attr), do: nil

  defp single_eq_value(%Normaliser.Normalised{disjuncts: disjuncts}, attr) do
    disjuncts
    |> Enum.reduce_while({:unset, nil}, fn disjunct, acc ->
      case Map.get(disjunct, attr) do
        %AshMultiDatalayer.Coverage.Interval{kind: :eq, values: [value]} ->
          case acc do
            {:unset, nil} -> {:cont, {:set, value}}
            {:set, ^value} -> {:cont, {:set, value}}
            {:set, _other} -> {:halt, :conflict}
          end

        _ ->
          {:halt, :conflict}
      end
    end)
    |> case do
      {:set, value} -> value
      _ -> nil
    end
  end
end
