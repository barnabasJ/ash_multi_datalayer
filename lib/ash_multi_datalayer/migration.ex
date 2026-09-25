defmodule AshMultiDatalayer.Migration do
  @moduledoc """
  Makes multi-datalayer resources visible to a stock per-datalayer migration
  generator (`AshPostgres.MigrationGenerator`, `AshSqlite.MigrationGenerator`,
  ...).

  Each stock generator only considers resources whose data layer *is* its own
  data layer module (a hard equality check), so a resource backed by
  `AshMultiDatalayer.DataLayer` would be silently skipped regardless of which
  concrete layers it wraps. This module builds lightweight *shadow modules* —
  one per resource and one per domain, per target data layer — that delegate
  all Spark introspection to the real module but report the target data layer
  as their own. Snapshots are keyed by table/repo, not module name, so the
  generated migrations are identical to what a plain twin of the resource
  (using that data layer directly) would produce.

  Used by `mix ash_multi_datalayer.generate_migrations` (Postgres),
  `mix ash_multi_datalayer.generate_sqlite_migrations` (SQLite), and the data
  layer's `codegen/1` (invoked by `mix ash.codegen`). Not intended for direct
  use.
  """

  alias AshMultiDatalayer.DataLayer.Info

  @doc """
  Whether the resource is a multi-datalayer resource with a `target_data_layer`
  layer (and therefore needs a shadow to participate in migration generation
  for that data layer).
  """
  @spec layered_as?(resource :: module(), target_data_layer :: module()) :: boolean()
  def layered_as?(resource, target_data_layer) do
    Ash.DataLayer.data_layer(resource) == AshMultiDatalayer.DataLayer and
      target_data_layer in Info.layer_modules(resource)
  end

  @doc """
  A module that introspects exactly like `resource` but reports
  `target_data_layer` as its data layer. Created on first use.
  """
  @spec shadow_resource(module(), module()) :: module()
  def shadow_resource(resource, target_data_layer) do
    shadow = shadow_name(resource, target_data_layer, Shadow)

    if shadow_built?(shadow) do
      shadow
    else
      build_resource_shadow(shadow, resource, target_data_layer)
    end
  end

  @doc """
  A module that introspects like `domain` but whose resource list contains
  shadows (for `target_data_layer`) for every multi-datalayer resource layered
  with it. Resources that don't have that layer pass through untouched (plain
  resources of that data layer are handled by the stock generator; others are
  ignored by its filter).
  """
  @spec shadow_domain(module(), module()) :: module()
  def shadow_domain(domain, target_data_layer) do
    shadow = shadow_name(domain, target_data_layer, ShadowDomain)

    if shadow_built?(shadow) do
      shadow
    else
      build_domain_shadow(shadow, domain, target_data_layer)
    end
  end

  @doc """
  Rewrites a relationship's source/destination to their shadows when they are
  multi-datalayer resources layered with `target_data_layer`. The generator
  decides foreign-key references by inspecting `relationship.source` and
  `relationship.destination` data layers, and those fields carry the real
  modules — without rewriting, references between multi-datalayer resources
  would be silently dropped.
  """
  def rewrite_relationship(relationship, target_data_layer) do
    relationship
    |> rewrite_field(:source, target_data_layer)
    |> rewrite_field(:destination, target_data_layer)
  end

  defp rewrite_field(relationship, field, target_data_layer) do
    case Map.fetch(relationship, field) do
      {:ok, module} when is_atom(module) ->
        if layered_as?(module, target_data_layer) do
          Map.put(relationship, field, shadow_resource(module, target_data_layer))
        else
          relationship
        end

      _ ->
        relationship
    end
  end

  defp shadow_name(base, target_data_layer, kind) do
    Module.concat([base, target_data_layer, kind])
  end

  defp shadow_built?(shadow) do
    Code.ensure_loaded?(shadow) and function_exported?(shadow, :spark_dsl_config, 0)
  end

  defp build_resource_shadow(shadow, resource, target_data_layer) do
    contents =
      quote bind_quoted: [resource: resource, target_data_layer: target_data_layer] do
        @moduledoc false
        @resource resource
        @target_data_layer target_data_layer

        def entities([:relationships]) do
          @resource.entities([:relationships])
          |> Enum.map(&AshMultiDatalayer.Migration.rewrite_relationship(&1, @target_data_layer))
        end

        def entities(path), do: @resource.entities(path)

        def fetch_opt(path, key), do: @resource.fetch_opt(path, key)
        def opt_anno(path, key), do: @resource.opt_anno(path, key)

        def persisted do
          Map.put(@resource.persisted(), :data_layer, @target_data_layer)
        end

        def persisted(key, default), do: Map.get(persisted(), key, default)
        def fetch_persisted(key), do: Map.fetch(persisted(), key)

        def spark_is, do: @resource.spark_is()

        def spark_dsl_config do
          Map.update(
            @resource.spark_dsl_config(),
            :persist,
            %{data_layer: @target_data_layer},
            &Map.put(&1, :data_layer, @target_data_layer)
          )
        end
      end

    {:module, ^shadow, _, _} = Module.create(shadow, contents, Macro.Env.location(__ENV__))
    shadow
  end

  defp build_domain_shadow(shadow, domain, target_data_layer) do
    resource_refs =
      domain
      |> Spark.Dsl.Extension.get_entities([:resources])
      |> Enum.map(fn ref ->
        if layered_as?(ref.resource, target_data_layer) do
          %{ref | resource: shadow_resource(ref.resource, target_data_layer)}
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
