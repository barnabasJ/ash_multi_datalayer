defmodule TodoClient.MultiDatalayerTest do
  @moduledoc """
  The proof: the client's generated resources run an ETS cache over
  `AshRemote.DataLayer`. Wire silence is asserted with an RPC-counting
  router (the inverse of ash_remote's own "the server WAS called" tests);
  cache semantics are asserted via the library's telemetry.
  """
  use TodoClient.MdlCase, async: false

  defp rpc, do: CountingRouter.rpc_count()

  describe "T1: repeated identical reads" do
    test "the second read never touches the server", %{list: list} do
      server_create_todo!(%{title: "Walk the dog", list_id: list.id})

      query = Ash.Query.filter(Todo, list_id == ^list.id)

      assert [%{title: "Walk the dog"}] = Ash.read!(query)
      assert_receive {:mdl, [_, :read, :miss], _, %{reason: :no_coverage_entry}}
      assert_receive {:mdl, [_, :read, :backfill], _, _}
      after_first = rpc()

      assert [%{title: "Walk the dog"}] = Ash.read!(query)
      assert rpc() == after_first
      assert_receive {:mdl, [_, :read, :hit], _, _}
    end
  end

  describe "T2: filter subsumption" do
    test "a narrower filter is served by broader coverage without an RPC", %{list: list} do
      server_create_todo!(%{title: "Active task", list_id: list.id})
      server_create_todo!(%{title: "Done task", list_id: list.id, completed: true})

      # Broad read warms the cache.
      assert [_, _] = Todo |> Ash.Query.filter(list_id == ^list.id) |> Ash.read!()
      warm = rpc()

      # Narrower: same list AND active only -> zero RPCs.
      assert [%{title: "Active task"}] =
               Todo
               |> Ash.Query.filter(list_id == ^list.id and completed == false)
               |> Ash.read!()

      assert rpc() == warm
      assert_receive {:mdl, [_, :read, :hit], _, _}
    end

    test "date-range containment", %{list: list} do
      server_create_todo!(%{title: "June", list_id: list.id, due_date: ~D[2026-06-15]})
      server_create_todo!(%{title: "December", list_id: list.id, due_date: ~D[2026-12-24]})

      year_start = ~D[2026-01-01]
      year_end = ~D[2026-12-31]
      june_start = ~D[2026-06-01]
      july_start = ~D[2026-07-01]

      Todo
      |> Ash.Query.filter(due_date >= ^year_start and due_date <= ^year_end)
      |> Ash.read!()

      warm = rpc()

      assert [%{title: "June"}] =
               Todo
               |> Ash.Query.filter(due_date >= ^june_start and due_date < ^july_start)
               |> Ash.read!()

      assert rpc() == warm
    end

    test "enum set containment", %{list: list} do
      server_create_todo!(%{title: "Urgent", list_id: list.id, priority: :high})
      server_create_todo!(%{title: "Normal", list_id: list.id, priority: :medium})
      server_create_todo!(%{title: "Someday", list_id: list.id, priority: :low})

      Todo |> Ash.Query.filter(priority in [:high, :medium]) |> Ash.read!()
      warm = rpc()

      assert [%{title: "Urgent"}] =
               Todo |> Ash.Query.filter(priority == :high) |> Ash.read!()

      assert rpc() == warm
    end

    test "negative control: a non-contained filter falls through", %{
      list: list,
      other_list: other_list
    } do
      server_create_todo!(%{title: "Here", list_id: list.id})
      server_create_todo!(%{title: "There", list_id: other_list.id})

      Todo |> Ash.Query.filter(list_id == ^list.id) |> Ash.read!()
      warm = rpc()

      assert [%{title: "There"}] =
               Todo |> Ash.Query.filter(list_id == ^other_list.id) |> Ash.read!()

      assert rpc() == warm + 1
    end
  end

  describe "T3: write-through with the server's returned record" do
    test "creates carry server-computed defaults into the cache", %{list: list} do
      # Warm coverage for the list.
      Todo |> Ash.Query.filter(list_id == ^list.id) |> Ash.read!()

      # Create through the client, sending ONLY title + list_id.
      created =
        Todo
        |> Ash.Changeset.for_create(:create, %{title: "Fresh", list_id: list.id})
        |> Ash.create!()

      # The returned record carries fields the CLIENT never set - the
      # server computed them (defaults + timestamps).
      assert created.completed == false
      assert created.priority == :medium
      assert created.inserted_at

      # Row-aware invalidation dropped the matching coverage...
      assert_receive {:mdl, [_, :ledger, :invalidated], _, _}
      before_read = rpc()

      # ...so the next read is a fall-through (correct, never-stale shape).
      assert [%{title: "Fresh"}] =
               Todo |> Ash.Query.filter(list_id == ^list.id) |> Ash.read!()

      assert rpc() == before_read + 1
      warm = rpc()

      # And the read after THAT is a hit whose row still carries the
      # server-computed values - i.e. the cache holds the returned record.
      assert [%{title: "Fresh", completed: false, priority: :medium, inserted_at: %DateTime{}}] =
               Todo |> Ash.Query.filter(list_id == ^list.id) |> Ash.read!()

      assert rpc() == warm
    end
  end

  describe "T4: row-aware invalidation" do
    test "an update drops only coverage matching the changed row", %{
      list: list,
      other_list: other_list
    } do
      server_create_todo!(%{title: "Here", list_id: list.id})
      server_create_todo!(%{title: "There", list_id: other_list.id})

      here = Todo |> Ash.Query.filter(list_id == ^list.id) |> Ash.read!() |> hd()
      Todo |> Ash.Query.filter(list_id == ^other_list.id) |> Ash.read!()
      warm = rpc()

      # Update the todo in `list` through the client.
      here
      |> Ash.Changeset.for_update(:update, %{title: "Here (edited)"})
      |> Ash.update!()

      # `list` coverage dropped -> fall-through with fresh data.
      assert [%{title: "Here (edited)"}] =
               Todo |> Ash.Query.filter(list_id == ^list.id) |> Ash.read!()

      assert rpc() == warm + 2

      # `other_list` coverage untouched -> still a hit.
      assert [%{title: "There"}] =
               Todo |> Ash.Query.filter(list_id == ^other_list.id) |> Ash.read!()

      assert rpc() == warm + 2
    end

    test "a row moving INTO a cached filter invalidates it", %{list: list} do
      server_create_todo!(%{title: "Open", list_id: list.id})

      # Warm "completed" coverage (currently empty).
      assert [] = Todo |> Ash.Query.filter(completed == true) |> Ash.read!()

      # Toggle through the client: the row now matches the cached filter.
      todo = Todo |> Ash.Query.filter(list_id == ^list.id) |> Ash.read!() |> hd()

      todo
      |> Ash.Changeset.for_update(:update, %{completed: true})
      |> Ash.update!()

      # The stale "[]" coverage was dropped; the read sees the toggled row.
      assert [%{title: "Open", completed: true}] =
               Todo |> Ash.Query.filter(completed == true) |> Ash.read!()
    end
  end

  describe "T5 (B): mirrored calcs are evaluated locally; remote calcs consult the server" do
    test "overdue? is computed from the cache with no RPC (local evaluation)", %{list: list} do
      server_create_todo!(%{title: "Late", list_id: list.id, due_date: ~D[2020-01-01]})
      server_create_todo!(%{title: "Future", list_id: list.id, due_date: ~D[2099-01-01]})

      # Warm plain coverage for the same filter.
      Todo |> Ash.Query.filter(list_id == ^list.id) |> Ash.read!()
      warm = rpc()

      # `overdue?` is the real mirrored server expression; the cache layer can
      # evaluate it from the covered rows, so loading it adds NO RPC.
      todos =
        Todo
        |> Ash.Query.filter(list_id == ^list.id)
        |> Ash.Query.load(:overdue?)
        |> Ash.read!()
        |> Map.new(&{&1.title, &1.overdue?})

      assert rpc() == warm
      assert_receive {:mdl, [_, :read, :hit], _, %{computed_values: :local}}

      # And the values carry the real server semantics — the 2099 row is not
      # overdue — proving the mirrored expression is evaluated, not a stub.
      assert todos == %{"Late" => true, "Future" => false}
    end

    test "todo_count folds from the cache (0 RPC); completed_count is forwarded to the server",
         %{list: list} do
      server_create_todo!(%{title: "One", list_id: list.id})
      server_create_todo!(%{title: "Done", list_id: list.id, completed: true})

      # Simulate the page's first load: it reads the lists AND their todos,
      # warming coverage for both (the todos are needed on the page anyway).
      TodoList |> Ash.Query.filter(id == ^list.id) |> Ash.read!()
      Todo |> Ash.Query.filter(list_id == ^list.id) |> Ash.read!()
      warm = rpc()

      # Reload: `todo_count` is a native aggregate the cache layer folds from the
      # covered todos — NO server round trip.
      assert [%{todo_count: 2}] =
               TodoList
               |> Ash.Query.filter(id == ^list.id)
               |> Ash.Query.load(:todo_count)
               |> Ash.read!()

      assert rpc() == warm

      # `completed_count` is opted out of folding (`fold_aggregate_overrides`) —
      # it is handed to the remote layer, forwarded to the server by name, and so
      # costs an RPC. The two aggregate strategies, side by side.
      assert [%{completed_count: 1}] =
               TodoList
               |> Ash.Query.filter(id == ^list.id)
               |> Ash.Query.load(:completed_count)
               |> Ash.read!()

      assert rpc() > warm

      # Because it round-trips, the forwarded aggregate observes out-of-band
      # server writes immediately.
      server_create_todo!(%{title: "Also done", list_id: list.id, completed: true})

      assert [%{completed_count: 2}] =
               TodoList
               |> Ash.Query.filter(id == ^list.id)
               |> Ash.Query.load(:completed_count)
               |> Ash.read!()
    end

    test "results are identical with the cache enabled and disabled", %{list: list} do
      server_create_todo!(%{title: "Alpha", list_id: list.id, due_date: ~D[2020-01-01]})
      server_create_todo!(%{title: "Bravo", list_id: list.id, completed: true})

      normalize = fn lists ->
        Enum.map(lists, fn l ->
          {l.id, l.todo_count, l.completed_count,
           l.todos |> Enum.map(&{&1.title, &1.completed, &1.overdue?}) |> Enum.sort()}
        end)
      end

      full_load = fn ->
        TodoList
        |> Ash.Query.load([:todo_count, :completed_count, :user, todos: [:overdue?]])
        |> Ash.Query.sort(:name)
        |> Ash.read!()
        |> normalize.()
      end

      with_cache = full_load.()

      AshMultiDatalayer.disable!(Todo)
      AshMultiDatalayer.disable!(TodoList)

      try do
        assert full_load.() == with_cache
      after
        AshMultiDatalayer.enable!(Todo)
        AshMultiDatalayer.enable!(TodoList)
      end
    end
  end

  describe "A: filter/sort on a remote calc forwards to the server" do
    test "filtering a list by todo_count (a remote calc) routes to the server", %{
      list: list,
      other_list: other_list
    } do
      server_create_todo!(%{title: "aaa", list_id: list.id})
      server_create_todo!(%{title: "bbb", list_id: list.id})
      # other_list has no todos.

      # Warm plain coverage for the lists.
      TodoList |> Ash.read!()
      warm = rpc()

      # `todo_count` is a `remote(...)` calc the cache can't evaluate, so the
      # filter routes to the remote layer, which forwards it to the server.
      names =
        TodoList
        |> Ash.Query.filter(todo_count > 1)
        |> Ash.read!()
        |> Enum.map(& &1.name)

      assert names == [list.name]
      refute other_list.name in names
      # The predicate reached the server (a source read happened).
      assert rpc() > warm
    end

    test "sorting by todo_count forwards to the server", %{list: list, other_list: other_list} do
      server_create_todo!(%{title: "aaa", list_id: list.id})
      server_create_todo!(%{title: "bbb", list_id: other_list.id})
      server_create_todo!(%{title: "ccc", list_id: other_list.id})

      names =
        TodoList
        |> Ash.Query.sort(todo_count: :desc)
        |> Ash.Query.load(:todo_count)
        |> Ash.read!()
        |> Enum.map(& &1.name)

      # other_list (2 todos) sorts ahead of list (1 todo).
      assert names == [other_list.name, list.name]
    end
  end

  describe "C: remainder reads — serve the covered part, fetch only the missing rows" do
    test "a partially-covered read fetches only the uncovered todos in one RPC", %{list: list} do
      server_create_todo!(%{title: "Open", list_id: list.id, completed: false})
      server_create_todo!(%{title: "Done", list_id: list.id, completed: true})

      # Warm coverage for the completed todos only.
      Todo
      |> Ash.Query.filter(list_id == ^list.id and completed == true)
      |> Ash.read!()

      warm = rpc()

      # Read every todo in the list: "Done" is served from the cache, and only
      # the remainder ("Open", i.e. completed != true) is fetched — one RPC.
      titles =
        Todo
        |> Ash.Query.filter(list_id == ^list.id)
        |> Ash.read!()
        |> Enum.map(& &1.title)
        |> Enum.sort()

      assert titles == ["Done", "Open"]
      assert rpc() == warm + 1
      assert_receive {:mdl, [_, :read, :partial], _, _}

      # The remainder backfilled + recorded Q: the next read is a full hit.
      Todo |> Ash.Query.filter(list_id == ^list.id) |> Ash.read!()
      assert rpc() == warm + 1
      assert_receive {:mdl, [_, :read, :hit], _, _}
    end
  end

  describe "T6: divergence detection" do
    test "an out-of-band server write is detected by the 1.0 sampler", %{list: list} do
      server_create_todo!(%{title: "watched", list_id: list.id})

      # Warm coverage through the sampled twin resource.
      query = Ash.Query.filter(SampledTodo, completed == false)
      assert [_] = Ash.read!(query)

      # Mutate the SERVER behind the client's back.
      server_create_todo!(%{title: "sneaky", list_id: list.id})

      # The next read is a (stale) cache hit; the sampler shadow-reads the
      # server and reports the drift.
      assert [_] = Ash.read!(query)

      assert_receive {:mdl, [_, :read, :divergence_detected], %{cache_count: 1, primary_count: 2},
                      %{pk_delta: %{only_in_cache: [], only_in_primary: [_]}}}
    end
  end

  describe "T7: kill-switch" do
    test "disable! routes around the cache; re-enable resumes hits", %{list: list} do
      server_create_todo!(%{title: "Steady", list_id: list.id})

      query = Ash.Query.filter(Todo, list_id == ^list.id)
      Ash.read!(query)
      Ash.read!(query)
      warm = rpc()

      AshMultiDatalayer.disable!(Todo)

      try do
        # Every read RPCs now...
        Ash.read!(query)
        Ash.read!(query)
        assert rpc() == warm + 2

        # ...and out-of-band changes are visible immediately.
        server_create_todo!(%{title: "Live", list_id: list.id})
        assert length(Ash.read!(query)) == 2

        # A write while disabled still invalidates coverage: no pre-switch
        # entries may survive to serve stale hits after re-enable.
        todo = query |> Ash.read!() |> Enum.find(&(&1.title == "Steady"))

        todo
        |> Ash.Changeset.for_update(:update, %{title: "Steady (edited)"})
        |> Ash.update!()

        assert AshMultiDatalayer.Debug.dump_ledger(Todo) == []
      after
        AshMultiDatalayer.enable!(Todo)
      end

      # Re-enabled: first read warms (miss), second hits.
      before_warm = rpc()
      Ash.read!(query)
      assert rpc() == before_warm + 1
      titles = Ash.read!(query) |> Enum.map(& &1.title) |> Enum.sort()
      assert rpc() == before_warm + 1
      assert titles == ["Live", "Steady (edited)"]
    end
  end
end
