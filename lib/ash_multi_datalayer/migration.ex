defmodule AshMultiDatalayer.Migration do
  @moduledoc """
  Makes multi-datalayer resources visible to `AshPostgres.MigrationGenerator`.

  The stock generator only considers resources whose data layer *is*
  `AshPostgres.DataLayer` (a hard equality check), so a resource backed by
  `AshMultiDatalayer.DataLayer` with a Postgres layer would be silently
  skipped. This module builds lightweight *shadow modules* — one per resource
  and one per domain — that delegate all Spark introspection to the real
  module but report `AshPostgres.DataLayer` as their data layer. Snapshots are
  keyed by table/repo, not module name, so the generated migrations are
  identical to what a plain-Postgres twin of the resource would produce.

  Used by `mix ash_multi_datalayer.generate_migrations` and the data layer's
  `codegen/1` (invoked by `mix ash.codegen`). Not intended for direct use.
  """

  @compile {:no_warn_undefined, [AshPostgres.DataLayer]}

  alias AshMultiDatalayer.DataLayer.Info

  @doc """
  Whether the resource is a multi-datalayer resource with a Postgres layer
  (and therefore needs a shadow to participate in migration generation).
  """
  @spec postgres_layered?(module()) :: boolean()
  def postgres_layered?(resource) do
    Ash.DataLayer.data_layer(resource) == AshMultiDatalayer.DataLayer and
      AshPostgres.DataLayer in Info.layer_modules(resource)
  end

  @doc """
  A module that introspects exactly like `resource` but reports
  `AshPostgres.DataLayer` as its data layer. Created on first use.
  """
  @spec shadow_resource(module()) :: module()
  def shadow_resource(resource) do
    shadow = Module.concat(resource, PostgresShadow)

    if shadow_built?(shadow) do
      shadow
    else
      build_resource_shadow(shadow, resource)
    end
  end

  @doc """
  A module that introspects like `domain` but whose resource list contains
  shadows for every postgres-layered multi-datalayer resource. Resources that
  are not multi-datalayer pass through untouched (plain Postgres resources are
  handled by the stock generator; others are ignored by its filter).
  """
  @spec shadow_domain(module()) :: module()
  def shadow_domain(domain) do
    shadow = Module.concat(domain, PostgresShadowDomain)

    if shadow_built?(shadow) do
      shadow
    else
      build_domain_shadow(shadow, domain)
    end
  end

  @doc """
  Rewrites a relationship's source/destination to their shadows when they are
  postgres-layered multi-datalayer resources. The generator decides
  foreign-key references by inspecting `relationship.source` and
  `relationship.destination` data layers, and those fields carry the real
  modules — without rewriting, references between multi-datalayer resources
  would be silently dropped.
  """
  def rewrite_relationship(relationship) do
    relationship
    |> rewrite_field(:source)
    |> rewrite_field(:destination)
  end

  defp rewrite_field(relationship, field) do
    case Map.fetch(relationship, field) do
      {:ok, module} when is_atom(module) ->
        if postgres_layered?(module) do
          Map.put(relationship, field, shadow_resource(module))
        else
          relationship
        end

      _ ->
        relationship
    end
  end

  defp shadow_built?(shadow) do
    Code.ensure_loaded?(shadow) and function_exported?(shadow, :spark_dsl_config, 0)
  end

  defp build_resource_shadow(shadow, resource) do
    contents =
      quote bind_quoted: [resource: resource] do
        @moduledoc false
        @resource resource

        def entities([:relationships]) do
          @resource.entities([:relationships])
          |> Enum.map(&AshMultiDatalayer.Migration.rewrite_relationship/1)
        end

        def entities(path), do: @resource.entities(path)

        def fetch_opt(path, key), do: @resource.fetch_opt(path, key)
        def opt_anno(path, key), do: @resource.opt_anno(path, key)

        def persisted do
          Map.put(@resource.persisted(), :data_layer, AshPostgres.DataLayer)
        end

        def persisted(key, default), do: Map.get(persisted(), key, default)
        def fetch_persisted(key), do: Map.fetch(persisted(), key)

        def spark_is, do: @resource.spark_is()

        def spark_dsl_config do
          Map.update(
            @resource.spark_dsl_config(),
            :persist,
            %{data_layer: AshPostgres.DataLayer},
            &Map.put(&1, :data_layer, AshPostgres.DataLayer)
          )
        end
      end

    {:module, ^shadow, _, _} = Module.create(shadow, contents, Macro.Env.location(__ENV__))
    shadow
  end

  defp build_domain_shadow(shadow, domain) do
    resource_refs =
      domain
      |> Spark.Dsl.Extension.get_entities([:resources])
      |> Enum.map(fn ref ->
        if postgres_layered?(ref.resource) do
          %{ref | resource: shadow_resource(ref.resource)}
        else
          ref
        end
      end)

    contents =
      quote bind_quoted: [domain: domain, resource_refs: Macro.escape(resource_refs)] do
        @moduledoc false
        @domain domain
        @resource_refs resource_refs

        def entities([:resources]), do: @resource_refs
        def entities(path), do: @domain.entities(path)

        def fetch_opt(path, key), do: @domain.fetch_opt(path, key)
        def opt_anno(path, key), do: @domain.opt_anno(path, key)

        def persisted, do: @domain.persisted()
        def persisted(key, default), do: @domain.persisted(key, default)
        def fetch_persisted(key), do: @domain.fetch_persisted(key)

        def spark_is, do: @domain.spark_is()
        def spark_dsl_config, do: @domain.spark_dsl_config()
      end

    {:module, ^shadow, _, _} = Module.create(shadow, contents, Macro.Env.location(__ENV__))
    shadow
  end
end
