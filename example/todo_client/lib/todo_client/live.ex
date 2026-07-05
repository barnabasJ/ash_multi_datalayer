defmodule TodoClient.Live do
  @moduledoc """
  A LiveView that manages todo lists living on the remote backend.

  Every read/write goes through the generated `TodoClient.Remote.*` resources,
  fronted by `AshMultiDatalayer` (an Ets cache over `AshRemote.DataLayer`). One
  `Ash.read!` demonstrates the full loading surface — and, on a warm reload, how
  little of it still touches the server:

    * `todo_count` — a native aggregate the cache layer **folds from the cached
      todos** (0 RPC when they're covered),
    * `completed_count` — the same kind of aggregate, but opted out of folding
      (`fold_aggregate_overrides`) so it is **forwarded to the server** (1 RPC) —
      the two aggregate strategies, side by side,
    * `overdue?` — a mirrored calculation evaluated locally from the cached row,
    * relationships (`user`, `todos`, and self-referential `subtasks`).
  """
  use Phoenix.LiveView

  require Ash.Query

  alias TodoClient.Remote.Todo
  alias TodoClient.Remote.TodoList

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(TodoClient.PubSub, TodoClient.CacheStats.topic())
    end

    lists = load_lists()

    {:ok,
     socket
     |> assign(lists: lists, form: new_form())
     |> assign(
       browse_list_id: lists |> List.first() |> then(&(&1 && &1.id)),
       browse_status: "all",
       browse_priority: "any",
       cache_stats: TodoClient.CacheStats.stats(),
       cache_enabled?: AshMultiDatalayer.enabled?(Todo)
     )
     |> assign_browse_todos()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width: 36rem; margin: 3rem auto; font-family: system-ui, sans-serif;">
      <h1>Todo lists <small style="color:#888;font-weight:400">via ash_remote</small></h1>

      <section :for={list <- @lists} style="margin-bottom:1.5rem;">
        <h2 style="display:flex; align-items:baseline; gap:.5rem; border-bottom:2px solid #ddd; padding-bottom:.3rem;">
          {list.name}
          <small :if={list.user} style="color:#888;font-weight:400">· {list.user.name}</small>
          <small style="margin-left:auto;color:#888;font-weight:400">
            <span title="native aggregate folded from the cached todos — 0 RPC on a warm reload">
              {list.todo_count} todos <span style="color:#2e7d32">·local</span>
            </span>
            <span title="aggregate opted out of folding — forwarded to the server by name">
              {list.completed_count} done <span style="color:#c62828">·server</span>
            </span>
          </small>
        </h2>

        <ul style="list-style: none; padding: 0;">
          <li :for={todo <- Enum.sort_by(list.todos, & &1.title)}>
            <.todo_row todo={todo} />
            <ul style="list-style: none; padding-left: 1.75rem;">
              <li :for={subtask <- Enum.sort_by(todo.subtasks, & &1.title)}>
                <.todo_row todo={subtask} />
              </li>
            </ul>
          </li>
        </ul>
      </section>

      <.form for={@form} phx-change="validate" phx-submit="save" style="display:flex; gap:.5rem; margin-top:1rem;">
        <input
          type="text"
          name={@form[:title].name}
          value={@form[:title].value}
          placeholder="New todo"
          style="flex:1; padding:.4rem;"
        />
        <select name={@form[:list_id].name} style="padding:.4rem;">
          <option :for={list <- @lists} value={list.id} selected={@form[:list_id].value == list.id}>
            {list.name}
          </option>
        </select>
        <button type="submit" style="padding:.4rem .8rem;">Add</button>
      </.form>
      <%!-- Errors from the mirrored validations — raised client-side, no RPC. --%>
      <p :for={error <- @form[:title].errors} style="color:#c00; margin:.3rem 0 0;">
        title {error_text(error)}
      </p>

      <%!-- Browse panel: plain-attribute filtered reads — the cache-eligible
           workload. Flip between tabs and watch the RPC log go quiet while
           the hit counter climbs. --%>
      <section style="margin-top:2.5rem; border-top:2px solid #ddd; padding-top:1rem;">
        <h2 style="display:flex; align-items:baseline; gap:.5rem;">
          Browse
          <small style="color:#888;font-weight:400">cached filtered reads via ash_multi_datalayer</small>
        </h2>

        <div style="display:flex; gap:.5rem; flex-wrap:wrap; margin-bottom:.75rem;">
          <form phx-change="browse-list" style="display:contents;">
            <select name="browse_list" style="padding:.3rem;">
              <option :for={list <- @lists} value={list.id} selected={@browse_list_id == list.id}>
                {list.name}
              </option>
            </select>
          </form>

          <span style="display:inline-flex; border:1px solid #ccc; border-radius:.4rem; overflow:hidden;">
            <button
              :for={status <- ~w(all active done)}
              phx-click="browse-status"
              phx-value-status={status}
              style={tab_style(@browse_status == status)}
            >
              {status}
            </button>
          </span>

          <span style="display:inline-flex; border:1px solid #ccc; border-radius:.4rem; overflow:hidden;">
            <button
              :for={priority <- ~w(any low medium high)}
              phx-click="browse-priority"
              phx-value-priority={priority}
              style={tab_style(@browse_priority == priority)}
            >
              {priority}
            </button>
          </span>
        </div>

        <ul style="list-style:none; padding:0;">
          <li
            :for={todo <- @browse_todos}
            style="display:flex; gap:.75rem; padding:.3rem 0; border-bottom:1px solid #eee;"
          >
            <span style={"flex:1;" <> if(todo.completed, do: "color:#999;text-decoration:line-through;", else: "")}>
              {todo.title}
            </span>
            <span style="font-size:.75rem;color:#888;">{todo.priority}</span>
            <span :if={todo.due_date} style="font-size:.75rem;color:#888;">{todo.due_date}</span>
          </li>
        </ul>
        <p :if={@browse_todos == []} style="color:#888;">nothing here</p>
      </section>

      <%!-- Cache stats footer, fed by ash_multi_datalayer telemetry. --%>
      <footer style="margin-top:2rem; padding:.6rem .8rem; background:#f6f6f6; border-radius:.5rem; display:flex; gap:1rem; align-items:center; font-size:.85rem; color:#555;">
        <span>
          cache: <b>{@cache_stats.hits}</b> hits · <b>{@cache_stats.misses}</b> misses ·
          <b>{@cache_stats.backfills}</b> backfills · <b>{@cache_stats.invalidations}</b> invalidations
          <span :if={@cache_stats.divergences > 0} style="color:#c00;">
            · {@cache_stats.divergences} divergences
          </span>
        </span>
        <button
          phx-click="cache-toggle"
          style={"margin-left:auto; padding:.3rem .7rem; border-radius:.4rem; border:1px solid #ccc; cursor:pointer; " <>
            if(@cache_enabled?, do: "background:#e6f7e6;", else: "background:#fbeaea;")}
        >
          cache {if @cache_enabled?, do: "ON", else: "OFF"}
        </button>
      </footer>
    </div>
    """
  end

  defp tab_style(true),
    do: "padding:.3rem .7rem; border:0; background:#333; color:#fff; cursor:pointer;"

  defp tab_style(false), do: "padding:.3rem .7rem; border:0; background:#fff; cursor:pointer;"

  defp error_text({message, vars}) do
    Enum.reduce(vars, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  defp error_text(message), do: to_string(message)

  defp todo_row(assigns) do
    ~H"""
    <div style="display:flex; align-items:center; gap:.5rem; padding:.4rem 0; border-bottom:1px solid #eee;">
      <input type="checkbox" checked={@todo.completed} phx-click="toggle" phx-value-id={@todo.id} />
      <span style={"flex:1;" <> if(@todo.completed, do: "text-decoration:line-through;color:#999;", else: "")}>
        {@todo.title}
      </span>
      <span
        :if={@todo.overdue?}
        style="font-size:.7rem;color:#fff;background:#c00;border-radius:.5rem;padding:.1rem .5rem;"
      >
        overdue
      </span>
      <span style="font-size:.75rem;color:#888;">{@todo.priority}</span>
      <button phx-click="delete" phx-value-id={@todo.id} style="border:0;background:none;cursor:pointer;color:#c00;">✕</button>
    </div>
    """
  end

  @impl true
  def handle_event("validate", %{"todo" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.form.source, params)
    {:noreply, assign(socket, form: to_form(form))}
  end

  def handle_event("save", %{"todo" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form.source, params: params) do
      {:ok, _todo} ->
        {:noreply,
         socket |> assign(lists: load_lists(), form: new_form()) |> assign_browse_todos()}

      {:error, form} ->
        {:noreply, assign(socket, form: to_form(form))}
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    todo = Ash.get!(Todo, id)
    Ash.update!(todo, %{completed: not todo.completed})
    {:noreply, socket |> assign(lists: load_lists()) |> assign_browse_todos()}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    Todo |> Ash.get!(id) |> Ash.destroy!()
    {:noreply, socket |> assign(lists: load_lists()) |> assign_browse_todos()}
  end

  def handle_event("browse-list", %{"browse_list" => id}, socket) do
    {:noreply, socket |> assign(browse_list_id: id) |> assign_browse_todos()}
  end

  def handle_event("browse-status", %{"status" => status}, socket) do
    {:noreply, socket |> assign(browse_status: status) |> assign_browse_todos()}
  end

  def handle_event("browse-priority", %{"priority" => priority}, socket) do
    {:noreply, socket |> assign(browse_priority: priority) |> assign_browse_todos()}
  end

  def handle_event("cache-toggle", _params, socket) do
    toggle = if socket.assigns.cache_enabled?, do: :disable!, else: :enable!

    for resource <- [Todo, TodoList, TodoClient.Remote.User] do
      apply(AshMultiDatalayer, toggle, [resource])
    end

    {:noreply,
     socket
     |> assign(cache_enabled?: AshMultiDatalayer.enabled?(Todo))
     |> assign_browse_todos()}
  end

  @impl true
  def handle_info({:cache_stats, stats}, socket) do
    {:noreply, assign(socket, cache_stats: stats)}
  end

  # The cache-eligible workload: plain attribute filters, no calculations or
  # aggregates. A broad list read warms the cache; the narrower status and
  # priority filters are then proven subsets, served from ETS with no RPC.
  defp assign_browse_todos(%{assigns: %{browse_list_id: nil}} = socket) do
    assign(socket, browse_todos: [])
  end

  defp assign_browse_todos(socket) do
    %{browse_list_id: list_id, browse_status: status, browse_priority: priority} =
      socket.assigns

    query = Ash.Query.filter(Todo, list_id == ^list_id)

    query =
      case status do
        "active" -> Ash.Query.filter(query, completed == false)
        "done" -> Ash.Query.filter(query, completed == true)
        _all -> query
      end

    query =
      case priority do
        "any" -> query
        value -> Ash.Query.filter(query, priority == ^String.to_existing_atom(value))
      end

    assign(socket, browse_todos: query |> Ash.Query.sort(:title) |> Ash.read!())
  end

  defp load_lists do
    TodoList
    |> Ash.Query.sort(:name)
    |> Ash.Query.load([
      :todo_count,
      :completed_count,
      :user,
      todos: [:overdue?, subtasks: [:overdue?]]
    ])
    |> Ash.read!()
  end

  defp new_form, do: Todo |> AshPhoenix.Form.for_create(:create, as: "todo") |> to_form()
end
