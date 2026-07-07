defmodule AshMultiDatalayer.RemoteContext do
  @moduledoc """
  Resolves application-supplied action context to attach to **target-layer**
  reads and writes an orchestrator performs on the app's behalf — the ones that
  do not ride a caller's changeset/query and therefore carry no ambient actor.

  The motivating case is the LocalOutbox strategy: flush pushes and hydration/
  stale-check reads run in a background Oban worker, built from stored outbox
  rows. There is no request actor in scope, so a networked
  replication target (e.g. `AshRemote.DataLayer`, which authenticates from
  `context[:private][:actor]` or `context[:ash_remote][:headers]`) would push/
  read unauthenticated. Configure a context provider and MDL threads it through:

      # a static map…
      config :ash_multi_datalayer, :remote_context,
        %{ash_remote: %{headers: %{"authorization" => "Bearer …"}}}

      # …or an MFA / 0-arity fun re-read on every call (fresh, rotatable token)
      config :ash_multi_datalayer, :remote_context, {MyApp.Session, :remote_context, []}

  The resolved map is deep-merged into the context of every `Backfill` write and
  `Target` read. It defaults to `%{}` — with no config, behaviour is unchanged.
  A single BEAM instance authenticated as one user (the common offline-client
  shape) supplies that user's credentials here; layers that ignore context (ETS,
  the local SQLite authority) are unaffected.
  """

  @doc "The configured context map (`{m,f,a}` / 0-arity fun re-read per call; map used as-is)."
  @spec resolve() :: map()
  def resolve do
    case Application.get_env(:ash_multi_datalayer, :remote_context, %{}) do
      {m, f, a} -> normalize(apply(m, f, a))
      fun when is_function(fun, 0) -> normalize(fun.())
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  @doc "Deep-merge the resolved context into `context` (resolved wins on leaf conflicts)."
  @spec merge(map() | nil) :: map()
  def merge(context), do: deep_merge(context || %{}, resolve())

  defp normalize(map) when is_map(map), do: map
  defp normalize(_), do: %{}

  defp deep_merge(left, right) do
    Map.merge(left, right, fn
      _key, %{} = l, %{} = r -> deep_merge(l, r)
      _key, _l, r -> r
    end)
  end
end
