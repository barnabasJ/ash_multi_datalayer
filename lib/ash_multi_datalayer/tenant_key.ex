defmodule AshMultiDatalayer.TenantKey do
  @moduledoc false

  @doc "Returns the canonical tenant partition for a read query."
  def query(resource, %{tenant: tenant, filter: filter}) do
    case Ash.Resource.Info.multitenancy_strategy(resource) do
      :attribute -> tenant || tenant_from_filter(resource, filter)
      _ -> tenant
    end
  end

  @doc "Returns the canonical tenant partition for a write changeset/result."
  def changeset(resource, changeset, record \\ nil) do
    case Ash.Resource.Info.multitenancy_strategy(resource) do
      :context -> changeset.to_tenant || to_tenant(resource, changeset.tenant)
      :attribute -> attribute_value(resource, record) || attribute_value(resource, changeset)
      _ -> nil
    end
  end

  @doc "Returns the canonical tenant partition for a record, falling back when needed."
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

  defp attribute_value(resource, record) do
    with attr when not is_nil(attr) <- Ash.Resource.Info.multitenancy_attribute(resource) do
      Map.get(record, attr)
    end
  end

  defp metadata_tenant(%{__metadata__: metadata}) when is_map(metadata), do: metadata[:tenant]
  defp metadata_tenant(_), do: nil

  defp tenant_from_filter(resource, filter) do
    attr = Ash.Resource.Info.multitenancy_attribute(resource)

    if attr do
      filter
      |> inspect(limit: :infinity)
      |> extract_filter_value(attr)
    end
  end

  defp extract_filter_value(nil, _attr), do: nil

  defp extract_filter_value(filter, attr) do
    attr = Atom.to_string(attr)

    case Regex.run(~r/#{Regex.escape(attr)}[^\n]*value: ([^,}\]]+)/, filter) do
      [_, value] -> parse_inspected_value(String.trim(value))
      _ -> nil
    end
  end

  defp parse_inspected_value(<<"\"", _::binary>> = value) do
    case Code.string_to_quoted(value) do
      {:ok, binary} when is_binary(binary) -> binary
      _ -> nil
    end
  end

  defp parse_inspected_value("nil"), do: nil
  defp parse_inspected_value(value), do: value
end
