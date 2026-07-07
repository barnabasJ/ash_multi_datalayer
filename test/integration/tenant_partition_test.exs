defmodule AshMultiDatalayer.Integration.TenantPartitionTest do
  @moduledoc """
  B3: `tenant_from_filter/2` must derive the SAME partition a write-side
  invalidation bumps, for an attribute-strategy resource — no permanent
  stale cache from a tenantless filtered read landing in `:__global__`
  while writes bump the real tenant's partition.
  """
  use AshMultiDatalayer.DataCase, async: false

  require Ash.Query

  alias AshMultiDatalayer.Test.CountingPostgres
  alias AshMultiDatalayer.Test.Tenancy.AttrPost
  alias AshMultiDatalayer.TenantKey

  defp pg_reads, do: CountingLayer.count(CountingPostgres, :run_query)

  defp warm!(query), do: Ash.read!(query)

  setup do
    AshMultiDatalayer.DataCase.reset_resource!(AttrPost)
    CountingLayer.reset!()
    :ok
  end

  defp create!(attrs) do
    AttrPost
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!()
  end

  test "a tenantless filtered read's coverage is invalidated by a same-tenant write" do
    acme = create!(%{org_id: "acme", title: "one"})

    query = Ash.Query.filter(AttrPost, org_id == "acme")
    assert [_] = warm!(query)
    assert pg_reads() == 1

    # Same read again -> cache hit, no second source read (proves it warmed
    # under a partition, not immediately re-fetched by coincidence).
    assert [_] = warm!(query)
    assert pg_reads() == 1

    acme
    |> Ash.Changeset.for_update(:update, %{title: "one-updated"})
    |> Ash.update!()

    # Unfixed code records the tenantless read under `:__global__` while the
    # write bumps the `"acme"` partition -> the entries never meet -> this
    # read would incorrectly stay a cache hit serving the stale title.
    assert [%{title: "one-updated"}] = warm!(query)
    assert pg_reads() == 2
  end

  test "zero-row filtered read still partitions correctly (no stale miss after a later create)" do
    query = Ash.Query.filter(AttrPost, org_id == "acme")
    assert [] = warm!(query)
    assert pg_reads() == 1

    create!(%{org_id: "acme", title: "new"})

    assert [%{title: "new"}] = warm!(query)
    assert pg_reads() == 2
  end

  test "an org_id filter does not collide with the similarly-named organization_id attribute" do
    post = create!(%{org_id: "acme", organization_id: "someone-else", title: "x"})

    # The multitenancy attribute is `org_id`; a filter that ALSO constrains
    # `organization_id` (an unrelated attribute whose name contains "org_id"
    # as a substring) must still derive "acme" from `org_id` — a
    # regex/substring-based extractor could instead false-match inside
    # "organization_id"'s own serialized text.
    query =
      Ash.Query.filter(AttrPost, org_id == "acme" and organization_id == "someone-else")

    assert [_] = warm!(query)
    assert pg_reads() == 1

    post
    |> Ash.Changeset.for_update(:update, %{title: "x-updated"})
    |> Ash.update!()

    assert [%{title: "x-updated"}] = warm!(query)
    assert pg_reads() == 2
  end

  test "multi-predicate/or/in filters derive correctly or conservatively refuse" do
    a = create!(%{org_id: "acme", title: "a"})
    _b = create!(%{org_id: "other", title: "b"})

    # `in` with a single value is equivalent to `==` — must derive "acme".
    single_in = Ash.Query.filter(AttrPost, org_id in ["acme"])
    assert [%{id: id}] = warm!(single_in)
    assert id == a.id
    assert pg_reads() == 1

    a
    |> Ash.Changeset.for_update(:update, %{title: "a-updated"})
    |> Ash.update!()

    assert [%{title: "a-updated"}] = warm!(single_in)
    assert pg_reads() == 2

    # An `or` across two DIFFERENT tenant values can't derive a single
    # partition — must conservatively refuse (never record under the wrong
    # single partition). We only assert this doesn't corrupt: reads stay
    # correct across a write to either side.
    CountingLayer.reset!()
    AshMultiDatalayer.Coverage.reset(AttrPost)

    or_query = Ash.Query.filter(AttrPost, org_id == "acme" or org_id == "other")
    assert length(warm!(or_query)) == 2

    a
    |> Ash.Changeset.for_update(:update, %{title: "a-updated-again"})
    |> Ash.update!()

    results = warm!(or_query)
    assert Enum.find(results, &(&1.id == a.id)).title == "a-updated-again"
  end

  test "TenantKey.canonical/2 stringifies integer/atom tenants via to_string, never inspect" do
    assert TenantKey.canonical(AttrPost, 42) == "42"
    assert TenantKey.canonical(AttrPost, :foo) == "foo"
    assert TenantKey.canonical(AttrPost, "acme") == "acme"
    assert TenantKey.canonical(AttrPost, nil) == TenantKey.unscoped()
  end

  # M2: `notification_tenant/2`'s changeset-less clause (`handle_external_
  # change` for a bare record, no changeset) must canonicalize the record's
  # raw metadata tenant before using it as a coverage partition key — the
  # same class of bug B3 fixes for the read-side filter derivation, just on
  # the notification-bridge path. Exercised via `TenantKey.record/3`'s
  # `:attribute` branch (strategy-agnostic fix: `notification_tenant/2`
  # calls `TenantKey.canonical/2` regardless of multitenancy strategy).
  test "M2: an inbound notification's raw (non-canonical) tenant invalidates the exact partition a prior read recorded" do
    post = create!(%{org_id: "42", title: "x"})

    query = Ash.Query.filter(AttrPost, org_id == "42")
    assert [_] = warm!(query)
    assert pg_reads() == 1

    # The notification's record carries the tenant as an ATOM, not the
    # canonical string "42" the read-side partitioned under — unfixed code
    # (`TenantKey.record/3`'s raw output used directly) would bump/evict the
    # WRONG partition (`:"42"` stringified via a different path, or simply
    # never matching "42"), leaving the "42" entry stale forever.
    notification = %Ash.Notifier.Notification{
      resource: AttrPost,
      data: %{post | org_id: :"42"},
      changeset: nil
    }

    :ok =
      AshMultiDatalayer.Orchestrator.ProvenCoverage.handle_external_change(AttrPost, notification)

    assert AshMultiDatalayer.Coverage.entries(AttrPost, "42") == []

    assert [_] = warm!(query)
    assert pg_reads() == 2
  end

  # L3 (tenant half): `write_through`'s inline drain calls
  # `TenantKey.changeset(resource, changeset, changeset.data)` BEFORE the
  # local write runs — for a create, `changeset.data` is the pre-write
  # struct (org_id not yet set there; it lives in `changeset.attributes`).
  # Unfixed code falls through to reading `Map.get(%Ash.Changeset{}, attr)`,
  # which is always nil (resource attributes are not `Ash.Changeset` struct
  # fields) — the create's tenant key is silently lost.
  test "L3: TenantKey.changeset/3 derives the tenant from changeset.attributes on a create" do
    changeset = Ash.Changeset.for_create(AttrPost, :create, %{org_id: "acme", title: "x"})

    assert TenantKey.changeset(AttrPost, changeset, changeset.data) == "acme"
  end

  # P4: `global? true` — a nil-tenant read spans every tenant and records
  # coverage under the unscoped partition; a later tenant-scoped write must
  # ALSO sweep that partition (not just its own), or the global entry keeps
  # serving the pre-write row forever.
  test "P4: a tenant-scoped write invalidates a prior nil-tenant (global) read" do
    post = create!(%{org_id: "acme", title: "one"})

    global_query = Ash.Query.filter(AttrPost, true)
    assert [_] = warm!(global_query)
    assert pg_reads() == 1

    post
    |> Ash.Changeset.for_update(:update, %{title: "one-updated"})
    |> Ash.update!()

    result = warm!(global_query)
    assert Enum.find(result, &(&1.id == post.id)).title == "one-updated"
    assert pg_reads() == 2
  end

  # Mirror case: a nil-tenant write (no org_id set) must invalidate a prior
  # tenant-scoped read that could have cached a row now falling out of (or
  # into) its scope.
  test "P4: a nil-tenant write invalidates a prior tenant-scoped read (mirror case)" do
    post = create!(%{org_id: "acme", title: "one"})

    tenant_query = Ash.Query.filter(AttrPost, org_id == "acme")
    assert [_] = warm!(tenant_query)
    assert pg_reads() == 1

    # A write with no derivable tenant (org_id cleared) — canonicalizes to
    # the unscoped partition — must sweep every known tenant partition too.
    post
    |> Ash.Changeset.for_update(:update, %{org_id: nil, title: "one-moved"})
    |> Ash.update!()

    # The row no longer matches `org_id == "acme"` at the source — unfixed
    # code would still serve the stale cache HIT (still showing the row with
    # its old title, `pg_reads() == 1`); the fix forces a fresh fetch that
    # correctly finds nothing.
    assert warm!(tenant_query) == []
    assert pg_reads() == 2
  end
end
