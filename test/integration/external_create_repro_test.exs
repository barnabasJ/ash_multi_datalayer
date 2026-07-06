defmodule AshMultiDatalayer.Integration.ExternalCreateReproTest do
  @moduledoc """
  Bug 2 reproduction: an external CREATE (a peer's write, arriving as a realtime
  notification) must become visible on the next read after the strategy's
  `handle_external_change/2` reaction — mirroring the demo's `/` list view,
  where `load_lists` reads a parent (TodoList/TestAuthor) and loads its `todos`
  relationship + a folded count aggregate.

  Peer writes go through `MirrorPost`/`MirrorAuthor` (plain AshPostgres sharing
  `mdl_posts`/`mdl_authors`) to simulate a write from OUTSIDE this node's
  `WriteDispatch` — the exact shape `forget!/3` reacts to.
  """
  use AshMultiDatalayer.DataCase, async: false

  require Ash.Query

  alias AshMultiDatalayer.Test.Resources.{MirrorAuthor, MirrorPost, TestAuthor, TestPost}

  setup do
    AshMultiDatalayer.TestSupport.reset!(TestAuthor)
    Ash.DataLayer.Ets.stop(TestAuthor)
    :ok
  end

  # The external-change reaction the notifier runs for a create, verbatim:
  # ProvenCoverage.handle_external_change → forget!(resource, record).
  defp react_to_create(record) do
    AshMultiDatalayer.forget!(TestPost, record)
  end

  defp as_test_post(%MirrorPost{} = m) do
    struct(TestPost, Map.take(m, [:id, :name, :age, :score, :published_at, :author_id]))
  end

  # The demo's `load_lists`: parent sorted, loading the child relationship (with
  # a calc on it, exactly as the demo loads `todos: [:overdue?]`) + the folded
  # count aggregate. The calc routes the child relationship read through
  # `merged_read` rather than plain `coverage_read`.
  defp load_authors do
    TestAuthor
    |> Ash.Query.sort(:name)
    |> Ash.Query.load([:post_count, posts: [:adult?]])
    |> Ash.read!()
  end

  test "external create in an already-cached (empty) parent appears on the next read" do
    author =
      MirrorAuthor
      |> Ash.Changeset.for_create(:create, %{name: "list-a"})
      |> Ash.create!()

    # Warm the cache exactly as the LiveView mount does: parent + empty posts +
    # count. Records coverage for the (empty) posts region.
    assert [%{name: "list-a", posts: [], post_count: 0}] = load_authors()
    # Also warm the Browse-style direct filtered read (a second coverage shape).
    assert [] = TestPost |> Ash.Query.filter(author_id == ^author.id) |> Ash.read!()

    # A peer creates a post in that parent (bypasses TestPost's WriteDispatch).
    peer_post =
      MirrorPost
      |> Ash.Changeset.for_create(:create, %{name: "peer-todo", age: 30, author_id: author.id})
      |> Ash.create!()

    # The realtime notification's reaction.
    react_to_create(as_test_post(peer_post))

    # The next read (the RealtimeBridge refetch) must show the new post.
    assert [%{posts: posts, post_count: post_count}] = load_authors()

    assert post_count == 1
    assert Enum.map(posts, & &1.name) == ["peer-todo"]
  end

  test "external create appears via a direct filtered child read (the Browse panel)" do
    author =
      MirrorAuthor
      |> Ash.Changeset.for_create(:create, %{name: "list-b"})
      |> Ash.create!()

    # Warm the Browse-panel read: TestPost filtered by author_id (empty).
    assert [] = TestPost |> Ash.Query.filter(author_id == ^author.id) |> Ash.read!()

    peer_post =
      MirrorPost
      |> Ash.Changeset.for_create(:create, %{name: "peer-2", age: 40, author_id: author.id})
      |> Ash.create!()

    react_to_create(as_test_post(peer_post))

    assert [%{name: "peer-2"}] =
             TestPost |> Ash.Query.filter(author_id == ^author.id) |> Ash.read!()
  end
end
