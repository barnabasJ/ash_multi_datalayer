defmodule AshMultiDatalayer.Orchestrator.LocalOutbox.HostResolver do
  @moduledoc """
  Resolves an outbox entry's persisted `resource` string back to its host
  resource module — WITHOUT minting or blindly trusting atoms (M-11 / pass-1
  S7, the same class as R-2 in ash_remote). `String.to_existing_atom/1`
  doesn't mint atoms, but it DOES raise for any string that isn't already an
  atom — including a stale outbox row for a resource the app has since
  removed (a boot-ordering/deploy artifact, not a security concern here, but
  a robustness one): that raise would crash the flush worker or resolution
  verb instead of degrading gracefully.

  Looks up a cached known-resource map instead: every module belonging to the
  OTP application that owns `outbox_module` (via
  `Application.get_application/1` + `:application.get_key/2` — no config
  required, just the `.app` resource file Mix already generates) that is a
  resource whose LocalOutbox config points at this exact outbox — keyed by
  its string form. A hit resolves to a module Ash itself already loaded and
  validated; a miss means the entry names a resource this app cannot serve,
  resolved or not.
  """

  alias AshMultiDatalayer.DataLayer.Info
  alias AshMultiDatalayer.Orchestrator.LocalOutbox

  @doc "The host resource module for `resource_string`, or `:error` if unresolvable."
  @spec resolve(module(), String.t()) :: {:ok, module()} | :error
  def resolve(outbox_module, resource_string) do
    Map.fetch(known_resources(outbox_module), resource_string)
  end

  defp known_resources(outbox_module) do
    key = {__MODULE__, outbox_module}

    case :persistent_term.get(key, :unset) do
      :unset ->
        map = build(outbox_module)
        :persistent_term.put(key, map)
        map

      map ->
        map
    end
  end

  defp build(outbox_module) do
    with otp_app when not is_nil(otp_app) <- Application.get_application(outbox_module),
         {:ok, modules} <- :application.get_key(otp_app, :modules) do
      modules
      |> Enum.filter(&local_outbox_onto?(&1, outbox_module))
      |> Map.new(&{Atom.to_string(&1), &1})
    else
      _ -> %{}
    end
  end

  defp local_outbox_onto?(resource, outbox_module) do
    Ash.DataLayer.data_layer(resource) == AshMultiDatalayer.DataLayer and
      match?({LocalOutbox, _}, Info.orchestrator(resource)) and
      LocalOutbox.outbox_resource(resource) == outbox_module
  rescue
    _ -> false
  end
end
