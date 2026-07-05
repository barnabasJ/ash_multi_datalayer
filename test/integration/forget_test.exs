defmodule AshMultiDatalayer.Integration.ForgetTest do
  @moduledoc """
  `AshMultiDatalayer.forget!/3` (fix-plan Phase 4.3) — the promoted
  row-purge API for consumers that discover staleness out-of-band (a lost
  notification: an external write already happened at the source, but
  nothing ever told this cache).
  """
  use AshMultiDatalayer.DataCase, async: false

  require Ash.Query

  alias AshMultiDatalayer.Coverage
  alias AshMultiDatalayer.Test.Resources.TestPost

  test "PK-only forget! drops an entry whose filter references a non-PK field, and evicts the ghost" do
    x =
      MirrorPost
      |> Ash.Changeset.for_create(:create, %{name: "x", age: 30})
      |> Ash.create!()

    # Warms coverage for a filter on a non-PK field (age), physically
    # caching the row.
    assert [%{name: "x"}] = TestPost |> Ash.Query.filter(age > 10) |> Ash.read!()
    assert [_] = Coverage.entries(TestPost, nil)

    # External destroy, out of band, with no accompanying notification.
    Ash.destroy!(x)

    assert :ok = AshMultiDatalayer.forget!(TestPost, %{id: x.id})

    # A nil-built probe would evaluate `age > 10` as a non-match and leave
    # the entry (and the physical ghost) untouched; the NotLoaded-built
    # probe degrades to :unknown, which is a conservative drop.
    assert Coverage.entries(TestPost, nil) == []

    # The ghost must not resurrect on a re-covering read.
    assert [] = TestPost |> Ash.Query.filter(age > 10) |> Ash.read!()
    assert [] = TestPost |> Ash.Query.filter(age > 10) |> Ash.read!()
  end

  test "forget! accepts a full record too" do
    x =
      MirrorPost
      |> Ash.Changeset.for_create(:create, %{name: "y", age: 40})
      |> Ash.create!()

    assert [%{name: "y"}] = TestPost |> Ash.Query.filter(age > 10) |> Ash.read!()

    record = struct(TestPost, Map.take(x, [:id, :name, :age, :score, :published_at]))
    Ash.destroy!(x)

    assert :ok = AshMultiDatalayer.forget!(TestPost, record)
    assert Coverage.entries(TestPost, nil) == []
    assert [] = TestPost |> Ash.Query.filter(age > 10) |> Ash.read!()
  end

  test "not_found?/1 recognizes NotFound in various error shapes" do
    refute AshMultiDatalayer.not_found?(:not_an_error)
    assert AshMultiDatalayer.not_found?(%Ash.Error.Query.NotFound{})
    assert AshMultiDatalayer.not_found?([%Ash.Error.Query.NotFound{}])
    assert AshMultiDatalayer.not_found?(%{errors: [%Ash.Error.Query.NotFound{}]})
    refute AshMultiDatalayer.not_found?(%{errors: []})
  end
end
