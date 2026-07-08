# L5 — Sweeper `{:global, ...}` name fails second-node boot; `RejectMultiNode` config timing

- **Status**: DONE — posture decided: **hard-reject, made deliberate** (not
  "genuinely multi-node-safe" — this app is single-node-only by design, per the
  README/ADR 20260417-single-node-v1). The `{:global, ...}` collision already
  made a second node's supervisor fail to boot; what was missing was making that
  failure legible. `Sweeper.start_link/1` now pattern-matches the
  `{:error, {:already_started, pid}}` collision specifically and logs a clear
  explanation (single-node-only, points at the ADR and the likely cause — a peer
  node joining the same distributed Erlang cluster) before returning the same
  `{:error, ...}` tuple unchanged — the supervisor still fails to boot exactly
  as before (no silent ignore, no change to failure semantics), but now with a
  legible reason instead of a bare OTP tuple.

  `RejectMultiNode`'s config-lookup timing (A7 item 4) resolved via the
  documented option: its moduledoc now states explicitly that the check is
  **compile-time only** (Spark verifiers run during `mix compile`, reading
  `Application.get_env/3` at that moment) and that `assume_single_node` set
  exclusively in `config/runtime.exs` or another release-time-only source is
  invisible to it.

  1 collision-focused test: starts the sweeper once, then starts a second one
  for the same resource set (a `{:global, ...}` name collision is
  node-count-independent — two processes can't hold the same global name even on
  one node, so this is a faithful simulation of the two-node scenario) — asserts
  `{:error, {:already_started, pid}}` AND that the logged message names the
  single-node-only reason. Confirmed via stash: the collision itself still
  happens on unfixed code (plain OTP behavior), but the explanatory log message
  is what's missing — discriminates the actual fix. Supervisor still starts
  cleanly in every other test (no change to the non-colliding path).
  `INTEGRATION=1 mix test` green (323, up from 322).

- **Severity**: Low (multi-node boot failure)
- **Repo**: MDL (ash_multi_datalayer)
- **Verification**: AGENT
- **Source**:
  [20260707 implementation review — L5](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Plan ref**: Workstream A phase A7 item 4 (RejectMultiNode runtime config)
- **Files**:
  `lib/ash_multi_datalayer/orchestrator/local_outbox/sweeper.ex:60-62`
  (untracked file)
- **Related task**: [P6](p6-lost-kick-recovery.md) — same `sweeper.ex` module
  (recovery semantics); a fix to one can perturb the other

## Defect

`name: {:global, {__MODULE__, sorted}}` — a second node's supervisor gets
`{:error, {:already_started, pid}}` and the MDL supervisor **fails to boot**.
Acceptable only if `RejectMultiNode` hard-fails multi-node anyway — but A7 item
4 (moving its config lookup from compile time to runtime, or documenting it as
compile-time) was also not addressed, so the posture is unresolved.

## Fix

Either make the sweeper genuinely multi-node-safe (a per-node local name with
work idempotent/deduped by Oban uniqueness, OR a proper singleton via a
global-registry failover story), or hard-reject multi-node before the sweeper
can collide. **Bare "ignore `already_started`" is not acceptable on its own**
(spec review): it hides the second-node supervisor failure while leaving that
node with no supervised sweeper and no failover — the second node then never
sweeps. Whichever posture is chosen must be proven by a collision-focused test,
not just "supervisor starts cleanly."

## Done when

- [ ] Decision recorded (multi-node-safe sweeper vs hard-reject) and implemented
- [ ] Collision-focused test proving the chosen posture: EITHER multi-node
      startup is hard-rejected before the sweeper collides, OR a real
      two-node/failover/idempotent-per-node test shows the selected behavior is
      safe (every node either sweeps or is deliberately not expected to)
- [ ] Supervisor starts cleanly in test and normal configs (plan A4 verify 4)
- [ ] `RejectMultiNode` config lookup timing resolved per A7 item 4
- [ ] `INTEGRATION=1 mix test` green in MDL
