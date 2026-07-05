defmodule AshMultiDatalayer.Sync.Transformers.InjectOutbox do
  @moduledoc """
  Injects the outbox-entry contract into a resource carrying the
  `AshMultiDatalayer.Sync.OutboxEntry` extension: attributes, actions, and the
  ash_oban `:flush` trigger — so the app's generated module is tiny (only its
  `sqlite`/`postgres` block and an `outbox_entry do queue …; max_attempts … end`
  config).

  Runs **before** `AshOban.Transformers.SetDefaults`, which both reads
  `[:oban, :triggers]` and validates each trigger's `action` exists — and this
  transformer injects both the trigger and its `:flush` action.
  """
  use Spark.Dsl.Transformer

  # `import` (not `require`): the `for_record` filter template references action
  # arguments via `arg/1`, a plain function in `Ash.Expr`.
  import Ash.Expr

  alias Spark.Dsl.Transformer

  @flush_runner AshMultiDatalayer.Orchestrator.LocalOutbox.Flush

  @impl true
  def before?(AshOban.Transformers.SetDefaults), do: true
  def before?(AshOban.Transformers.DefineSchedulers), do: true
  def before?(_), do: false

  @impl true
  def transform(dsl) do
    queue = Spark.Dsl.Extension.get_opt(dsl, [:outbox_entry], :queue, nil)
    max_attempts = Spark.Dsl.Extension.get_opt(dsl, [:outbox_entry], :max_attempts, 10)
    module = Transformer.get_persisted(dsl, :module)

    dsl
    |> add_attributes()
    |> add_actions()
    |> add_trigger(queue, max_attempts, module)
  end

  # --- attributes --------------------------------------------------------

  defp add_attributes(dsl) do
    dsl
    |> attr(:integer_primary_key, name: :seq)
    |> attr(:attribute,
      name: :write_ref,
      type: :uuid,
      allow_nil?: false,
      default: &Ash.UUID.generate/0,
      public?: true
    )
    |> attr(:attribute, name: :resource, type: :string, allow_nil?: false, public?: true)
    # `:string`, not `:term`: the SQLite client stack rejects multitenant
    # resources (ash_sqlite `can?(:multitenancy) == false`), so `tenant` is
    # normally nil or a simple identifier — keeping it TEXT keeps the outbox
    # table SQLite-portable.
    |> attr(:attribute, name: :tenant, type: :string, public?: true)
    |> attr(:attribute, name: :record_pk, type: :map, allow_nil?: false, public?: true)
    |> attr(:attribute,
      name: :op,
      type: :atom,
      constraints: [one_of: [:create, :update, :upsert, :destroy]],
      allow_nil?: false,
      public?: true
    )
    |> attr(:attribute, name: :payload, type: :map, public?: true)
    |> attr(:attribute, name: :base_image, type: :map, public?: true)
    |> attr(:attribute, name: :remote_snapshot, type: :map, public?: true)
    |> attr(:attribute, name: :target, type: :atom, allow_nil?: false, public?: true)
    |> attr(:attribute,
      name: :state,
      type: :atom,
      constraints: [one_of: [:pending, :parked]],
      default: :pending,
      allow_nil?: false,
      public?: true
    )
    |> attr(:attribute,
      name: :error_class,
      type: :atom,
      constraints: [one_of: [:transient_exhausted, :rejected, :conflict]],
      public?: true
    )
    |> attr(:attribute, name: :last_error, type: :map, public?: true)
    |> attr(:attribute, name: :parked_at, type: :utc_datetime_usec, public?: true)
    |> attr(:create_timestamp, name: :inserted_at)
    |> attr(:update_timestamp, name: :updated_at)
  end

  defp attr(dsl, entity_name, opts) do
    {:ok, entity} = Transformer.build_entity(Ash.Resource.Dsl, [:attributes], entity_name, opts)
    Transformer.add_entity(dsl, [:attributes], entity, type: :append)
  end

  # --- actions -----------------------------------------------------------

  @write_fields [
    :write_ref,
    :resource,
    :tenant,
    :record_pk,
    :op,
    :payload,
    :base_image,
    :target
  ]

  defp add_actions(dsl) do
    dsl
    |> add_action(:read, :read, primary?: true)
    |> add_action(:create, :enqueue, accept: @write_fields)
    |> add_flush_action()
    |> add_park_action()
    |> add_retry_action()
    |> add_action(:destroy, :discard, [])
    |> add_read(:pending, filter: [state: :pending], sort: [seq: :asc], keyset?: true)
    |> add_read(:parked, filter: [state: :parked], sort: [seq: :asc], keyset?: true)
    |> add_for_record_read()
  end

  defp add_action(dsl, type, name, opts) do
    {:ok, action} =
      Transformer.build_entity(Ash.Resource.Dsl, [:actions], type, [name: name] ++ opts)

    Transformer.add_entity(dsl, [:actions], action, type: :append)
  end

  # The worker action — generic, so no atomic read precedes it; its body is
  # `LocalOutbox.Flush.run/2` (library code, so fixes ship in the library).
  defp add_flush_action(dsl) do
    {:ok, arg} =
      Transformer.build_entity(Ash.Resource.Dsl, [:actions, :action], :argument,
        name: :primary_key,
        type: :map,
        allow_nil?: false
      )

    {:ok, action} =
      Transformer.build_entity(Ash.Resource.Dsl, [:actions], :action,
        name: :flush,
        returns: :term,
        arguments: [arg],
        run: {@flush_runner, []}
      )

    Transformer.add_entity(dsl, [:actions], action, type: :append)
  end

  # parked ← pending: records error_class/last_error/remote_snapshot/parked_at.
  defp add_park_action(dsl) do
    {:ok, set_state} =
      Transformer.build_entity(Ash.Resource.Dsl, [:actions, :update], :change,
        change: {Ash.Resource.Change.SetAttribute, attribute: :state, value: :parked}
      )

    {:ok, set_parked_at} =
      Transformer.build_entity(Ash.Resource.Dsl, [:actions, :update], :change,
        change:
          {Ash.Resource.Change.SetAttribute, attribute: :parked_at, value: &DateTime.utc_now/0}
      )

    {:ok, action} =
      Transformer.build_entity(Ash.Resource.Dsl, [:actions], :update,
        name: :park,
        accept: [:error_class, :last_error, :remote_snapshot],
        require_atomic?: false,
        changes: [set_state, set_parked_at]
      )

    Transformer.add_entity(dsl, [:actions], action, type: :append)
  end

  # parked → pending: clears the error; the caller re-triggers the chain head.
  defp add_retry_action(dsl) do
    changes =
      for {attr, value} <- [state: :pending, error_class: nil, last_error: nil, parked_at: nil] do
        {:ok, change} =
          Transformer.build_entity(Ash.Resource.Dsl, [:actions, :update], :change,
            change: {Ash.Resource.Change.SetAttribute, attribute: attr, value: value}
          )

        change
      end

    {:ok, action} =
      Transformer.build_entity(Ash.Resource.Dsl, [:actions], :update,
        name: :retry,
        require_atomic?: false,
        changes: changes
      )

    Transformer.add_entity(dsl, [:actions], action, type: :append)
  end

  defp add_read(dsl, name, opts) do
    {:ok, filter} =
      Transformer.build_entity(Ash.Resource.Dsl, [:actions, :read], :filter,
        filter: opts[:filter]
      )

    {:ok, pagination} =
      Transformer.build_entity(Ash.Resource.Dsl, [:actions, :read], :pagination,
        keyset?: Keyword.get(opts, :keyset?, false),
        required?: false
      )

    {:ok, prepare} =
      Transformer.build_entity(Ash.Resource.Dsl, [:actions, :read], :prepare,
        preparation: {AshMultiDatalayer.Sync.Preparations.SortSeq, sort: opts[:sort]}
      )

    {:ok, action} =
      Transformer.build_entity(Ash.Resource.Dsl, [:actions], :read,
        name: name,
        filters: [filter],
        pagination: pagination,
        preparations: [prepare]
      )

    Transformer.add_entity(dsl, [:actions], action, type: :append)
  end

  # `for_record`: the pending-or-parked chain for a (resource, record_pk, target).
  defp add_for_record_read(dsl) do
    args =
      for {name, type} <- [resource: :string, record_pk: :map, target: :atom] do
        {:ok, arg} =
          Transformer.build_entity(Ash.Resource.Dsl, [:actions, :read], :argument,
            name: name,
            type: type,
            allow_nil?: false
          )

        arg
      end

    {:ok, filter} =
      Transformer.build_entity(Ash.Resource.Dsl, [:actions, :read], :filter,
        filter:
          Ash.Expr.expr(
            resource == ^arg(:resource) and record_pk == ^arg(:record_pk) and
              target == ^arg(:target)
          )
      )

    {:ok, prepare} =
      Transformer.build_entity(Ash.Resource.Dsl, [:actions, :read], :prepare,
        preparation: {AshMultiDatalayer.Sync.Preparations.SortSeq, sort: [seq: :asc]}
      )

    {:ok, action} =
      Transformer.build_entity(Ash.Resource.Dsl, [:actions], :read,
        name: :for_record,
        arguments: args,
        filters: [filter],
        preparations: [prepare]
      )

    Transformer.add_entity(dsl, [:actions], action, type: :append)
  end

  # --- ash_oban trigger --------------------------------------------------

  defp add_trigger(dsl, queue, max_attempts, module) do
    {:ok, trigger} =
      Transformer.build_entity(AshOban, [:oban, :triggers], :trigger,
        name: :flush,
        action: :flush,
        queue: queue,
        read_action: :pending,
        worker_read_action: :pending,
        where: expr(state == :pending),
        sort: [seq: :asc],
        max_attempts: max_attempts,
        # No `on_error`: ash_oban does not run it for generic-action triggers
        # (Phase 2 finding) — the flush action self-parks. Sweeping is MDL-owned,
        # so ash_oban's own scheduler is disabled.
        scheduler_cron: false,
        # Set explicitly (plan facts) so a trigger rename never dangles jobs and
        # MDL's enqueue helper has a stable worker module to build against.
        worker_module_name: Module.concat(module, AshOban.Worker.Flush),
        scheduler_module_name: Module.concat(module, AshOban.Scheduler.Flush)
      )

    {:ok, Transformer.add_entity(dsl, [:oban, :triggers], trigger, type: :append)}
  end
end
