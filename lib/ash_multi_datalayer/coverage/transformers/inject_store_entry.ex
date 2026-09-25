defmodule AshMultiDatalayer.Coverage.Transformers.InjectStoreEntry do
  @moduledoc """
  Injects the coverage-store contract into a resource carrying the
  `AshMultiDatalayer.Coverage.StoreEntry` extension: attributes, the unique
  `:coverage_entry` identity an upsert-create relies on, and the
  `:record`/`:read`/`:destroy` actions `AshMultiDatalayer.Coverage.Store` calls
  — so the app's generated module can be as small as its `sqlite`/`postgres`
  block, with zero hand-written attributes or actions.
  """
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  # Must run before Ash core caches the primary key (and other
  # attribute-derived state) from the DSL's attribute list — otherwise the
  # injected `:id` attribute added below is invisible to that cache, and
  # every later `Ash.Resource.Info.primary_key/1` call (which a data layer's
  # own upsert/update internals rely on, e.g. `Ash.DataLayer.Ets`) sees `[]`.
  @impl true
  def before?(Ash.Resource.Transformers.CachePrimaryKey), do: true
  def before?(_), do: false

  @impl true
  def transform(dsl) do
    dsl =
      dsl
      |> add_attributes()
      |> add_identity()
      |> add_actions()

    {:ok, dsl}
  end

  # --- attributes ----------------------------------------------------------

  defp add_attributes(dsl) do
    dsl
    |> attr(:uuid_primary_key, name: :id)
    |> attr(:attribute, name: :resource, type: :string, allow_nil?: false, public?: true)
    # Both `tenant` and `filter`/`normalised` below round-trip arbitrary Elixir
    # terms via `:erlang.term_to_binary/1` (see `AshMultiDatalayer.Coverage.Store`'s
    # moduledoc) — always encoded, even a `nil` tenant/filter, so this column is
    # never a real SQL NULL. That matters for `tenant`: it is part of the
    # `:coverage_entry` unique identity below, and standard SQL treats NULL as
    # distinct from every other NULL for uniqueness purposes — an unencoded nil
    # tenant would let duplicate untenanted rows through the upsert.
    |> attr(:attribute, name: :tenant, type: :binary, allow_nil?: false, public?: true)
    |> attr(:attribute, name: :fingerprint, type: :integer, allow_nil?: false, public?: true)
    |> attr(:attribute, name: :normalised, type: :binary, allow_nil?: false, public?: true)
    |> attr(:attribute, name: :filter, type: :binary, allow_nil?: false, public?: true)
    |> attr(:attribute,
      name: :loaded_fields,
      type: {:array, :string},
      default: [],
      allow_nil?: false,
      public?: true
    )
    |> attr(:attribute, name: :loaded_at, type: :utc_datetime_usec, allow_nil?: false, public?: true)
    |> attr(:create_timestamp, name: :inserted_at)
    |> attr(:update_timestamp, name: :updated_at)
  end

  defp attr(dsl, entity_name, opts) do
    {:ok, entity} = Transformer.build_entity(Ash.Resource.Dsl, [:attributes], entity_name, opts)
    Transformer.add_entity(dsl, [:attributes], entity, type: :append)
  end

  # --- identity --------------------------------------------------------------

  # The natural dedupe key for a ledger entry (mirrors `Coverage.do_record/5`'s
  # own `fingerprint`+`normalised` match): one row per resource+tenant+filter,
  # so a widened or re-recorded entry upserts in place instead of
  # accumulating duplicate rows.
  #
  # `Ash.DataLayer.Ets` has no native unique-constraint/conflict-detection
  # mechanism, so it requires every identity to declare `pre_check_with:` (a
  # domain to run an explicit existence read through before the upsert) — a
  # real, documented Ets limitation (`Ash.DataLayer.Verifiers.RequirePreCheckWith`),
  # not specific to this extension. A SQL layer (the production path) checks
  # identities natively and must NOT pay that extra read on every ledger
  # write, so this only applies when Ets is the configured data layer — e.g.
  # a test fixture (see `AshMultiDatalayer.Coverage.StoreEntry`'s moduledoc:
  # Ets is a documented, supported `coverage_store` choice for tests).
  defp add_identity(dsl) do
    opts =
      [name: :coverage_entry, keys: [:resource, :tenant, :fingerprint]] ++
        pre_check_with_opt(dsl)

    {:ok, identity} = Transformer.build_entity(Ash.Resource.Dsl, [:identities], :identity, opts)
    Transformer.add_entity(dsl, [:identities], identity, type: :append)
  end

  defp pre_check_with_opt(dsl) do
    if Transformer.get_persisted(dsl, :data_layer) == Ash.DataLayer.Ets do
      # `pre_check_with:` alone only satisfies `RequirePreCheckWith`'s compile-time
      # check — the before-action pre-check hook itself is gated by `pre_check?`,
      # which defaults to false. Both are needed.
      [pre_check?: true, pre_check_with: Transformer.get_persisted(dsl, :domain)]
    else
      []
    end
  end

  # --- actions ---------------------------------------------------------------

  @write_fields [:resource, :tenant, :fingerprint, :normalised, :filter, :loaded_fields, :loaded_at]
  @upsert_fields [:normalised, :filter, :loaded_fields, :loaded_at]

  defp add_actions(dsl) do
    dsl
    |> add_action(:read, :read, primary?: true)
    |> add_record_action()
    |> add_action(:destroy, :destroy, primary?: true, accept: [])
  end

  defp add_action(dsl, type, name, opts) do
    {:ok, action} =
      Transformer.build_entity(Ash.Resource.Dsl, [:actions], type, [name: name] ++ opts)

    Transformer.add_entity(dsl, [:actions], action, type: :append)
  end

  defp add_record_action(dsl) do
    {:ok, action} =
      Transformer.build_entity(Ash.Resource.Dsl, [:actions], :create,
        name: :record,
        primary?: true,
        accept: @write_fields,
        upsert?: true,
        upsert_identity: :coverage_entry,
        upsert_fields: @upsert_fields
      )

    Transformer.add_entity(dsl, [:actions], action, type: :append)
  end
end
