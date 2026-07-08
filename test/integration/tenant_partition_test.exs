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

  # M2 (behavioral, post-simplification): a changeset-less notification's
  # tenant comes from the record itself; whatever partition it lands in, the
  # `global? true` sweep must still reach the partition a prior tenantless
  # filtered read recorded under — no stale cache.
  test "M2: an inbound notification's raw (non-canonical) tenant invalidates the exact partition a prior read recorded" do
    post = create!(%{org_id: "42", title: "x"})

    query = Ash.Query.filter(AttrPost, org_id == "42")
    assert [_] = warm!(query)
    assert pg_reads() == 1

    # The notification's record carries the tenant as an ATOM — whatever
    # partition that maps to, the `global? true` sweep must still reach the
    # partition the prior tenantless read recorded under.
    notification = %Ash.Notifier.Notification{
      resource: AttrPost,
      data: %{post | org_id: :"42"},
      changeset: nil
    }

    :ok =
      AshMultiDatalayer.Orchestrator.ProvenCoverage.handle_external_change(AttrPost, notification)

    assert [_] = warm!(query)
    assert pg_reads() == 2
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

  # M1: ash_postgres returns `{:ok, {:upsert_skipped, query, callback}}` for
  # a condition-skipped upsert — `record` here is NOT a struct. Unfixed
  # WriteDispatch.dispatch/4 passed it straight to
  # the changeset-carried tenant (attribute-multitenant
  # resources extract the tenant FROM the record), which crashed with
  # `BadMapError` AFTER the (no-op) write already "succeeded" — instead of
  # the clean `StaleRecord` error Ash core surfaces by default for a skipped
  # upsert (`return_skipped_upsert?: true`, which would hand back the
  # existing row via the skip tuple's callback, hits an unrelated
  # pre-existing ash_postgres/explicitly-delegated-layer callback-plumbing
  # issue not in M1's scope — this test only needs the tuple to survive
  # `dispatch/4` intact, which the clean StaleRecord error already proves).
  test "M1: a condition-skipped upsert on an attribute-multitenant resource surfaces a clean StaleRecord error, not a crash" do
    create!(%{org_id: "acme", title: "one", version: 5})

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
             AttrPost
             |> Ash.Changeset.for_create(:upsert_if_newer, %{
               org_id: "acme",
               title: "one",
               version: 1
             })
             |> Ash.create()
  end
end
