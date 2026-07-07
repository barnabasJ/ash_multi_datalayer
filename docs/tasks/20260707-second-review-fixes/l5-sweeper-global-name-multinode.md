# L5 — Sweeper `{:global, ...}` name fails second-node boot; `RejectMultiNode` config timing

- **Status**: OPEN
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
