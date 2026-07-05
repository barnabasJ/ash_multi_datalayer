defmodule AshMultiDatalayer.Sync.Verifiers.VerifyDataLayer do
  @moduledoc """
  A resource carrying the `AshMultiDatalayer.Sync.OutboxEntry` extension must run
  on a SQL-backed data layer (ash_sqlite or ash_postgres) — Oban requires a SQL
  engine and the outbox is durable state — and must carry the `AshOban`
  extension (the extension adds it automatically; this is the belt-and-suspenders
  check).
  """
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @sql_data_layers [AshSqlite.DataLayer, AshPostgres.DataLayer]

  @impl true
  def verify(dsl) do
    data_layer = Ash.Resource.Info.data_layer(dsl)
    module = Verifier.get_persisted(dsl, :module)

    cond do
      data_layer not in @sql_data_layers ->
        error(
          module,
          "the AshMultiDatalayer.Sync.OutboxEntry extension requires a SQL-backed data " <>
            "layer (AshSqlite.DataLayer or AshPostgres.DataLayer), because Oban needs a SQL " <>
            "engine and the outbox is durable state. Got: #{inspect(data_layer)}."
        )

      AshOban not in Verifier.get_persisted(dsl, :extensions, []) ->
        error(
          module,
          "the AshMultiDatalayer.Sync.OutboxEntry extension requires the AshOban extension " <>
            "(it is normally added automatically via `add_extensions`)."
        )

      true ->
        :ok
    end
  end

  defp error(module, message) do
    {:error,
     Spark.Error.DslError.exception(module: module, path: [:outbox_entry], message: message)}
  end
end
