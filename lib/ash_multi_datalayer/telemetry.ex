defmodule AshMultiDatalayer.Telemetry do
  @moduledoc """
  Telemetry emission for `ash_multi_datalayer`.

  Events (all prefixed `[:ash_multi_datalayer, ...]`):

    * `[:read, :hit]` — a read served from an earlier layer via coverage
    * `[:read, :partial]` — a remainder read: the covered part served from the
      cache, only the uncovered remainder fetched from the source (metadata
      `%{cached, fetched}` row counts)
    * `[:read, :miss]` — a read that fell through (metadata `reason:` one of
      `:no_coverage_entry`, `:solver_unsupported`, `:fields_insufficient`,
      `:not_cacheable`, `:calc_sort_source_only`, `:ledger_unavailable`)
    * `[:read, :forced]` — a read routed raw to a named layer via the
      `read_from` context escape hatch (metadata `%{layer}`)
    * `[:read, :backfill]` — fetched rows upserted into earlier layers +
      the filter recorded in the ledger
    * `[:read, :divergence_detected]` — a sampled cache hit disagreed with
      the source of truth (measurements `%{cache_count, primary_count}`,
      metadata includes `pk_delta`)
    * `[:write, :applied]` / `[:write, :failed_at_layer]`
    * `[:ledger, :invalidated]` / `[:ledger, :evicted]` / `[:ledger, :full]`

  Read/write/ledger events carry measurements `%{duration_us, ledger_size}`
  where applicable and metadata
  `%{resource, tenant, filter_fingerprint, read_order, write_order}`.

  Filter fingerprints are structural hashes with literal values replaced by
  type tags — PII-safe by construction. Raw filters never appear in
  telemetry.
  """

  alias Ash.Query.{BooleanExpression, Not, Ref}
  alias AshMultiDatalayer.DataLayer.Info

  @prefix :ash_multi_datalayer

  @doc """
  A structural, PII-safe fingerprint of a filter: the shape of the
  expression with every literal replaced by a type tag. Two filters that
  differ only in literal values fingerprint identically; filters that differ
  in operators or attributes do not.
  """
  @spec fingerprint(Ash.Filter.t() | term()) :: non_neg_integer()
  def fingerprint(filter), do: :erlang.phash2(shape(filter))

  defp shape(%Ash.Filter{expression: expression}), do: shape(expression)
  defp shape(nil), do: :no_filter

  defp shape(%BooleanExpression{op: op, left: left, right: right}),
    do: {op, shape(left), shape(right)}

  defp shape(%Not{expression: expression}), do: {:not, shape(expression)}
  defp shape(%Ref{relationship_path: path, attribute: %{name: name}}), do: {:ref, path, name}
  defp shape(%Ref{relationship_path: path, attribute: name}), do: {:ref, path, name}

  defp shape(%struct{__predicate__?: _} = predicate) do
    {struct, shape_operand(predicate)}
  end

  defp shape(other), do: {:value, type_tag(other)}

  defp shape_operand(%{left: left, right: right}), do: {shape(left), shape(right)}
  defp shape_operand(%{arguments: arguments}), do: Enum.map(arguments, &shape/1)
  defp shape_operand(_), do: :none

  defp type_tag(value) when is_binary(value), do: :string
  defp type_tag(value) when is_boolean(value), do: :boolean
  defp type_tag(value) when is_integer(value), do: :integer
  defp type_tag(value) when is_float(value), do: :float
  defp type_tag(value) when is_atom(value), do: :atom
  defp type_tag(%Date{}), do: :date
  defp type_tag(%DateTime{}), do: :datetime
  defp type_tag(%Decimal{}), do: :decimal
  defp type_tag(%MapSet{} = values), do: {:set, values |> Enum.map(&type_tag/1) |> Enum.uniq()}

  defp type_tag(values) when is_list(values),
    do: {:list, values |> Enum.map(&type_tag/1) |> Enum.uniq()}

  defp type_tag(%struct{}), do: {:struct, struct}
  defp type_tag(value) when is_map(value), do: :map
  defp type_tag(_), do: :other

  @doc "Emits a read event with standard metadata."
  def read(kind, resource, query, measurements, extra_metadata \\ %{}) do
    :telemetry.execute(
      [@prefix, :read, kind],
      measurements,
      Map.merge(metadata(resource, query.tenant, query.filter), extra_metadata)
    )
  end

  @doc "Emits a write event with standard metadata."
  def write(kind, resource, tenant, measurements, extra_metadata \\ %{}) do
    :telemetry.execute(
      [@prefix, :write, kind],
      measurements,
      Map.merge(metadata(resource, tenant, nil), extra_metadata)
    )
  end

  @doc "Emits a ledger event with standard metadata."
  def ledger(kind, resource, tenant, measurements, extra_metadata \\ %{}) do
    :telemetry.execute(
      [@prefix, :ledger, kind],
      measurements,
      Map.merge(metadata(resource, tenant, nil), extra_metadata)
    )
  end

  defp metadata(resource, tenant, filter) do
    %{
      resource: resource,
      tenant: tenant,
      filter_fingerprint: filter && fingerprint(filter),
      read_order: Info.read_order(resource),
      write_order: Info.write_order(resource)
    }
  end

  @doc "Microseconds elapsed since a `System.monotonic_time/0` timestamp."
  def duration_us(started) do
    System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond)
  end
end
