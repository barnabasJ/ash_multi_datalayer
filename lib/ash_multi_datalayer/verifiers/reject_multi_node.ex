defmodule AshMultiDatalayer.Verifiers.RejectMultiNode do
  @moduledoc """
  Warns unless the host application has acknowledged that
  `ash_multi_datalayer` v1 is single-node-only.

  The cache layers (ETS) and the coverage ledger are node-local; a write on
  node A does not invalidate node B's cache. Setting

      config :ash_multi_datalayer, :assume_single_node, true

  silences the warning and serves as the documented acknowledgement. See ADR
  20260417-single-node-v1.

  **This check is compile-time only (L5, A7 item 4)**: Spark DSL verifiers
  run during `mix compile`, reading `Application.get_env/3` at that moment —
  the same compile-time config visibility every other MDL verifier has (see
  the README's `--warnings-as-errors` section). Setting
  `assume_single_node` **only** in `config/runtime.exs` (or another
  release-time-only source, e.g. an env var read at boot) is invisible to
  this verifier; put it in `config/config.exs` (or an environment-specific
  compile-time config file) for the acknowledgement to actually take
  effect. A release that sets it exclusively at runtime will see this
  warning at every build regardless of the runtime value.
  """
  use Spark.Dsl.Verifier

  @impl true
  def verify(_dsl_state) do
    if Application.get_env(:ash_multi_datalayer, :assume_single_node, false) do
      :ok
    else
      {:warn,
       "ash_multi_datalayer v1 is single-node-only: the cache and coverage " <>
         "ledger are node-local, so peer nodes can serve stale reads. Set " <>
         "`config :ash_multi_datalayer, :assume_single_node, true` to " <>
         "acknowledge this limitation. See ADR 20260417-single-node-v1."}
    end
  end
end
