defmodule AshMultiDatalayer.Sync.OutboxEntry do
  @moduledoc """
  Spark extension that turns a SQL-backed Ash resource into a LocalOutbox entry
  store. Add it (AshOban comes along automatically) and configure only the queue:

      defmodule TodoClient.Sync.OutboxEntry do
        use Ash.Resource,
          domain: TodoClient.Sync,
          data_layer: AshSqlite.DataLayer,
          extensions: [AshMultiDatalayer.Sync.OutboxEntry]

        sqlite do
          table "amd_outbox_entries"
          repo TodoClient.Repo
        end

        outbox_entry do
          queue :todo_sync
          max_attempts 10
        end
      end

  The extension injects the full contract — attributes (`seq`, `write_ref`,
  `resource`, `tenant`, `record_pk`, `op`, `payload`, `base_image`,
  `remote_snapshot`, `target`, `state`, `error_class`, `last_error`,
  `parked_at`, timestamps), actions (`enqueue`, `flush`, `park`, `retry`,
  `discard`, `pending`/`parked`/`for_record` reads), and the ash_oban `:flush`
  trigger — so the orchestrator can rely on the shape while the app owns the
  module (attach notifiers, pub_sub, policies, extra actions). See the
  sync-state-as-Ash-resources ADR and the LocalOutbox RFC.

  Generate one with `mix ash_multi_datalayer.gen.outbox`.
  """
  @outbox_entry %Spark.Dsl.Section{
    name: :outbox_entry,
    describe: """
    Configures the auto-injected outbox entry contract and its ash_oban flush
    trigger.
    """,
    examples: [
      """
      outbox_entry do
        queue :todo_sync
        max_attempts 10
      end
      """
    ],
    schema: [
      queue: [
        type: :atom,
        required: true,
        doc: "The Oban queue flush jobs run on."
      ],
      max_attempts: [
        type: :pos_integer,
        default: 10,
        doc: "Transient-retry budget before an entry parks."
      ],
      oban_instance: [
        type: :atom,
        default: Oban,
        doc: "The named Oban instance MDL inserts flush jobs into."
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@outbox_entry],
    add_extensions: [AshOban],
    transformers: [AshMultiDatalayer.Sync.Transformers.InjectOutbox],
    verifiers: [AshMultiDatalayer.Sync.Verifiers.VerifyDataLayer]
end
