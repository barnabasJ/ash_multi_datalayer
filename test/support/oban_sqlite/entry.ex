defmodule AshMultiDatalayer.Test.ObanSqlite.Entry do
  @moduledoc """
  Phase 2 walking-skeleton resource: an outbox-style entry on `AshSqlite.DataLayer`
  with an `AshOban` `:flush` trigger, executed by Oban Lite.

  Shape mirrors the real `OutboxEntry` closely enough to de-risk every
  third-party assumption:

    * `seq` — **`integer_primary_key`** → SQLite `INTEGER PRIMARY KEY` (rowid,
      autoincrementing). This is the per-PK ordering key (plan Phase 2 item 9);
      `ref` (uuid) is demoted to a secondary identity.
    * `payload` / `base_image` — `:map` attributes, round-tripping a record
      snapshot (item 10 — dumped-map encoding).
    * `behavior` — a test knob the `:flush` action reads to simulate each flush
      outcome (ok / snooze / reject / transient), so items 2–5 are exercised
      through the real trigger → worker → action path.
  """
  use Ash.Resource,
    domain: AshMultiDatalayer.Test.ObanSqlite.SkeletonDomain,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshOban]

  alias AshMultiDatalayer.Test.ObanSqlite.Probe

  sqlite do
    table "amd_skeleton_entries"
    repo(AshMultiDatalayer.Test.ObanSqlite.SkeletonRepo)
  end

  attributes do
    integer_primary_key :seq

    attribute :ref, :uuid do
      allow_nil? false
      default &Ash.UUID.generate/0
      public? true
    end

    attribute :record_pk, :map, public?: true
    attribute :payload, :map, public?: true
    attribute :base_image, :map, public?: true

    attribute :state, :atom do
      constraints one_of: [:pending, :parked]
      default :pending
      allow_nil? false
      public? true
    end

    attribute :error_class, :atom do
      constraints one_of: [:transient_exhausted, :rejected, :conflict]
      public? true
    end

    attribute :attempts, :integer, default: 0, public?: true

    # Test knob: what the flush action should simulate.
    attribute :behavior, :atom do
      constraints one_of: [:ok, :snooze, :reject, :transient]
      default :ok
      allow_nil? false
      public? true
    end

    attribute :name, :string, public?: true
    # Dedup key for the unique-job test.
    attribute :token, :string, public?: true

    timestamps()
  end

  identities do
    identity :unique_ref, [:ref]
  end

  actions do
    defaults [:read, :destroy, update: :*]

    create :enqueue do
      accept [:ref, :record_pk, :payload, :base_image, :name, :token, :behavior]
    end

    # ash_oban's scheduler streams the trigger's `read_action` with keyset
    # pagination (plan Phase 2 item 7 — keyset rides Ash-level pagination; there
    # is no ash_sqlite capability flag to check).
    read :pending do
      filter expr(state == :pending)
      prepare build(sort: [seq: :asc])
      pagination keyset?: true, required?: false
    end

    update :park do
      accept [:error_class]
      change set_attribute(:state, :parked)
    end

    # The worker action. Generic (no atomic read before it), so its body is the
    # worker's first Ash call — the sound place to read `job.conf.name`.
    action :flush, :atom do
      argument :primary_key, :map, allow_nil?: false

      run fn input, context ->
        AshMultiDatalayer.Test.ObanSqlite.Entry.run_flush(input, context)
      end
    end
  end

  oban do
    triggers do
      trigger :flush do
        action :flush
        queue(:skeleton_flush)
        worker_read_action(:pending)
        read_action :pending
        where expr(state == :pending)
        sort seq: :asc
        max_attempts(3)
        on_error(:park)
        # Sweeping is MDL-owned in the real strategy; disable ash_oban's own
        # scheduler cron so nothing auto-fires (plan Phase 2 item 11).
        scheduler_cron(false)
        worker_module_name(AshMultiDatalayer.Test.ObanSqlite.Entry.FlushWorker)
        scheduler_module_name(AshMultiDatalayer.Test.ObanSqlite.Entry.FlushScheduler)
      end
    end
  end

  @doc false
  # The flush body. Loads the entry by primary key (the worker's first Ash
  # call), records the running Oban instance (`job.conf.name`) + run count via
  # the Probe, then simulates the entry's `behavior`.
  def run_flush(input, context) do
    seq = pk_seq(input.arguments.primary_key)
    job = job_from_context(context, input)
    instance = job && job.conf.name

    domain = AshMultiDatalayer.Test.ObanSqlite.SkeletonDomain
    entry = Ash.get!(__MODULE__, %{seq: seq}, domain: domain, authorize?: false)

    Probe.record(entry.ref, instance)

    case entry.behavior do
      :ok ->
        # Success: a synced entry has no further meaning — delete it.
        Ash.destroy!(entry, domain: domain, authorize?: false)
        {:ok, :flushed}

      :snooze ->
        # Offline-class: reschedule with zero retry-budget burn.
        raise AshOban.Errors.SnoozeJob, snooze_for: 1

      :reject ->
        # Semantic rejection: park immediately, complete the job (no retries).
        park(entry, domain, :rejected)
        {:ok, :parked}

      :transient ->
        # Transient-while-connected: raise so Oban retries. NB (Phase 2 finding):
        # ash_oban's `on_error` does NOT run for generic-action triggers — its
        # `handle_error` is only wired into update/destroy performs. So the
        # action must self-park at the last attempt instead of relying on
        # `on_error`.
        if job && job.attempt >= job.max_attempts do
          park(entry, domain, :transient_exhausted)
          {:ok, :parked}
        else
          raise "transient flush failure for entry #{seq} (attempt #{job && job.attempt})"
        end
    end
  end

  defp park(entry, domain, error_class) do
    entry
    |> Ash.Changeset.for_update(:park, %{error_class: error_class},
      domain: domain,
      authorize?: false
    )
    |> Ash.update!()
  end

  defp pk_seq(pk) when is_map(pk), do: pk["seq"] || pk[:seq]

  # The ash_oban job lands in the action context under `:ash_oban`. Read it
  # robustly from either the Implementation.Context or the input context.
  defp job_from_context(context, input) do
    from_ctx(Map.get(context, :source_context)) ||
      from_ctx(context) ||
      from_ctx(input.context)
  end

  defp from_ctx(ctx) when is_map(ctx) do
    case ctx do
      %{ash_oban: %{job: job}} -> job
      %{private: %{ash_oban: %{job: job}}} -> job
      _ -> nil
    end
  end

  defp from_ctx(_), do: nil
end
