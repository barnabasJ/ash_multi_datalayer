defmodule AshMultiDatalayer.Sync.Info do
  @moduledoc """
  Introspection for the `outbox_entry` DSL section injected by
  `AshMultiDatalayer.Sync.OutboxEntry`.
  """
  alias Spark.Dsl.Extension

  @doc "The Oban queue flush jobs run on."
  @spec queue(Ash.Resource.t() | Spark.Dsl.t()) :: atom() | nil
  def queue(resource), do: Extension.get_opt(resource, [:outbox_entry], :queue, nil)

  @doc "The transient-retry budget before an entry parks."
  @spec max_attempts(Ash.Resource.t() | Spark.Dsl.t()) :: pos_integer()
  def max_attempts(resource), do: Extension.get_opt(resource, [:outbox_entry], :max_attempts, 10)

  @doc "The named Oban instance MDL inserts flush jobs into (default `Oban`)."
  @spec oban_instance(Ash.Resource.t() | Spark.Dsl.t()) :: atom()
  def oban_instance(resource),
    do: Extension.get_opt(resource, [:outbox_entry], :oban_instance, Oban)
end
