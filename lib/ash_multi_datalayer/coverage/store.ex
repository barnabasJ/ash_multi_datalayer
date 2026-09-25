defmodule AshMultiDatalayer.Coverage.Store do
  @moduledoc """
  Optional persistence for the coverage ledger (see `AshMultiDatalayer.Coverage`).

  By default the ledger is ETS-only: fast, but wiped on every BEAM restart —
  the first read after every restart is a guaranteed cold-start miss,
  regardless of how warm the ledger was a moment before. Configuring a
  `coverage_store:` closes that gap by mirroring every ledger write into an
  app-owned Ash resource, and restoring from it at boot
  (`AshMultiDatalayer.Orchestrator.ProvenCoverage.child_specs/1`).

  ## Configuring

      multi_data_layer do
        orchestrator {AshMultiDatalayer.Orchestrator.ProvenCoverage,
          coverage_store: MyApp.Coverage.Entry}

        layer :cache, Ash.DataLayer.Ets
        layer :remote, MyApp.Remote.Todo
        read_order [:cache, :remote]
        write_order [:remote, :cache]
      end

  `coverage_store:` names an Ash resource carrying the
  `AshMultiDatalayer.Coverage.StoreEntry` extension (generate one with `mix
  ash_multi_datalayer.gen.coverage_store`). Omitting the option is fully
  backward compatible — every function here degrades to a no-op
  (`configured?/1` is the single gate every other function checks first).

  Deliberately **not** a hard dependency on any particular data layer: unlike
  `AshMultiDatalayer.Orchestrator.LocalOutbox`'s `outbox_resource:` (which
  requires a SQL layer because its Oban-backed flush jobs need one), the
  coverage store has no background jobs — any `Ash.DataLayer` the consuming
  app already has on hand (SQLite, Postgres, even ETS-with-a-different-name
  for tests) works. `ash_sqlite` only appears as the generator's convenience
  default.

  ## Correctness posture

  Every write here is fire-and-forget and best-effort: a failure is logged and
  swallowed, never raised into the caller. The coverage ledger is a
  performance optimization, not a correctness mechanism — losing a persisted
  row (or restoring a stale one) costs a cache hit, never a wrong read.
  `AshMultiDatalayer.Coverage.record/5`'s own epoch protocol is what
  guarantees correctness on the READ path; this module only tries to make
  cold starts less cold.

  ## Serialization

  `resource` and `tenant` and the `Entry`'s `filter`/`normalised` fields are
  arbitrary Elixir terms (a filter is an AST of `Ash.Query.Ref`/operator
  structs; a tenant can be any term an app's multitenancy uses) with no
  natural JSON-safe encoding. Rather than hand-roll a partial encoder for an
  open-ended term shape, they round-trip via `:erlang.term_to_binary/1` and
  `:erlang.binary_to_term/1` into `:binary` attributes — the standard,
  general-purpose way to persist an arbitrary Elixir term. `loaded_fields`
  (a `MapSet` of attribute-name atoms, always already-existing atoms since
  they came from the resource's own attribute list) is stored as a plain
  `{:array, :string}` instead, for a store that stays human-inspectable for
  the common case.
  """

  require Ash.Query
  require Logger

  alias AshMultiDatalayer.Coverage.Entry
  alias AshMultiDatalayer.DataLayer.Info

  @doc "Whether `resource` has a `coverage_store:` configured."
  @spec configured?(module()) :: boolean()
  def configured?(resource), do: not is_nil(store_resource(resource))

  # Every caller in this module treats "not a multi_data_layer resource at
  # all" (e.g. a bare test double module) identically to "no coverage_store
  # configured" — both mean there is nothing to persist to. `Info.coverage_store/1`
  # raises `ArgumentError` for the former (Spark's "not a Spark DSL module"
  # signal); this is the single place that folds it into the latter.
  defp store_resource(resource) do
    Info.coverage_store(resource)
  rescue
    ArgumentError -> nil
  end

  @doc """
  Fire-and-forget upsert of `entry`'s current state into the configured
  coverage store. No-ops (`:ok`) when unconfigured; otherwise returns
  `{:ok, pid}` for the (unlinked) task doing the write — every caller in this
  library ignores it, but tests use it to synchronize on completion via
  `Process.monitor/1` instead of polling.
  """
  @spec persist_async(module(), term(), Entry.t()) :: {:ok, pid()} | :ok
  def persist_async(resource, tenant, %Entry{} = entry) do
    with_store(resource, fn store -> persist(store, resource, tenant, entry) end)
  end

  @doc """
  Fire-and-forget delete of `entry`'s persisted counterpart. No-ops when
  unconfigured. See `persist_async/3` on the returned task pid.
  """
  @spec delete_async(module(), term(), Entry.t()) :: {:ok, pid()} | :ok
  def delete_async(resource, tenant, %Entry{} = entry) do
    with_store(resource, fn store -> delete(store, resource, tenant, entry) end)
  end

  @doc """
  Fire-and-forget delete of every persisted row for `resource`, across every
  tenant. No-ops when unconfigured. See `persist_async/3` on the returned
  task pid.
  """
  @spec clear_resource_async(module()) :: {:ok, pid()} | :ok
  def clear_resource_async(resource) do
    with_store(resource, fn store -> clear_resource(store, resource) end)
  end

  @doc """
  Synchronously restores every persisted entry for `resource` into its ETS
  ledger. Called once at boot, before the app serves traffic — see
  `AshMultiDatalayer.Orchestrator.ProvenCoverage.child_specs/1`.

  Each restored entry gets a fresh `id` (`make_ref/0`): an ETS entry's id is
  an Erlang reference, meaningful only within the BEAM incarnation that
  created it — the persisted row's own primary key plays no role in ETS
  identity. Restoring inserts directly via `AshMultiDatalayer.Coverage`'s raw
  ETS primitive, bypassing the write-through hook, so a restore does not
  immediately re-persist the very rows it just read.

  A store the app can't read from yet (e.g. a pending migration) logs and
  degrades to a cold start — never crashes boot.
  """
  @spec restore(module()) :: :ok
  def restore(resource) do
    case store_resource(resource) do
      nil -> :ok
      store -> do_restore(store, resource)
    end
  end

  defp with_store(resource, fun) do
    case store_resource(resource) do
      nil ->
        :ok

      store ->
        Task.Supervisor.start_child(AshMultiDatalayer.Coverage.Store.TaskSupervisor, fn ->
          fun.(store)
        end)
    end
  catch
    :exit, {:noproc, _} ->
      warn_once(
        resource,
        "AshMultiDatalayer.Coverage.Store.TaskSupervisor is not running — add " <>
          "AshMultiDatalayer.Supervisor to your application's supervision tree for " <>
          "coverage-store persistence to take effect."
      )
  end

  defp persist(store, resource, tenant, %Entry{} = entry) do
    attrs = %{
      resource: Atom.to_string(resource),
      tenant: :erlang.term_to_binary(tenant),
      fingerprint: entry.fingerprint,
      normalised: :erlang.term_to_binary(entry.normalised),
      filter: :erlang.term_to_binary(entry.filter),
      loaded_fields: Enum.map(entry.loaded_fields, &Atom.to_string/1),
      loaded_at: entry.loaded_at
    }

    store
    |> Ash.Changeset.for_create(:record, attrs, domain: domain(store))
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, _record} -> :ok
      {:error, reason} -> log_failure(:persist, resource, reason)
    end
  rescue
    error -> log_failure(:persist, resource, error)
  end

  # `allow_stream_with: :full_read` sidesteps `Ash.bulk_destroy`'s default
  # requirement that the query stream via keyset pagination — the generated
  # `:read` action declares none (see `InjectStoreEntry`), and the ledger
  # table is small/local, so loading it fully before destroying is the right
  # tradeoff over adding pagination to a store resource nothing else queries.
  defp delete(store, resource, tenant, %Entry{} = entry) do
    store
    |> Ash.Query.for_read(:read, %{}, domain: domain(store))
    |> Ash.Query.filter(
      resource == ^Atom.to_string(resource) and
        tenant == ^:erlang.term_to_binary(tenant) and
        fingerprint == ^entry.fingerprint
    )
    |> Ash.bulk_destroy(:destroy, %{},
      authorize?: false,
      return_errors?: false,
      allow_stream_with: :full_read
    )
    |> case do
      %Ash.BulkResult{status: :error} = result -> log_failure(:delete, resource, result.errors)
      _ -> :ok
    end
  rescue
    error -> log_failure(:delete, resource, error)
  end

  defp clear_resource(store, resource) do
    store
    |> Ash.Query.for_read(:read, %{}, domain: domain(store))
    |> Ash.Query.filter(resource == ^Atom.to_string(resource))
    |> Ash.bulk_destroy(:destroy, %{},
      authorize?: false,
      return_errors?: false,
      allow_stream_with: :full_read
    )
    |> case do
      %Ash.BulkResult{status: :error} = result -> log_failure(:clear, resource, result.errors)
      _ -> :ok
    end
  rescue
    error -> log_failure(:clear, resource, error)
  end

  defp do_restore(store, resource) do
    store
    |> Ash.Query.for_read(:read, %{}, domain: domain(store))
    |> Ash.Query.filter(resource == ^Atom.to_string(resource))
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, rows} -> Enum.each(rows, &restore_row(resource, &1))
      {:error, reason} -> log_failure(:restore, resource, reason)
    end

    :ok
  rescue
    error -> log_failure(:restore, resource, error)
  end

  defp restore_row(resource, row) do
    entry = %Entry{
      id: make_ref(),
      tenant: :erlang.binary_to_term(row.tenant),
      filter: :erlang.binary_to_term(row.filter),
      normalised: :erlang.binary_to_term(row.normalised),
      fingerprint: row.fingerprint,
      loaded_fields: MapSet.new(row.loaded_fields, &String.to_existing_atom/1),
      loaded_at: row.loaded_at
    }

    AshMultiDatalayer.Coverage.restore_insert(resource, entry.tenant, entry)
  rescue
    error -> log_failure(:restore_row, resource, error)
  end

  defp domain(store), do: Ash.Resource.Info.domain(store)

  defp log_failure(step, resource, reason) do
    Logger.warning(
      "ash_multi_datalayer coverage-store #{step} failed for #{inspect(resource)}: " <>
        "#{inspect(reason)}"
    )
  end

  defp warn_once(resource, message) do
    key = {:ash_multi_datalayer, :coverage_store_warning_logged, resource}

    unless :persistent_term.get(key, false) do
      :persistent_term.put(key, true)
      Logger.warning(message)
    end
  end
end
