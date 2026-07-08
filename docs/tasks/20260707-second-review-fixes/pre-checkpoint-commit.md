# PRE — Checkpoint-commit the uncommitted working tree (do FIRST)

- **Status**: DONE — verified, not newly performed: both repos' named Cat A
  files are already committed (from before this session's own work began — this
  session's entire commit history builds directly on top of that baseline). MDL:
  `capability.ex`, `supervisor.ex`, `flush.ex`, `write.ex`, `enqueue.ex`,
  `tenant_key.ex`, `sweeper.ex` — all tracked, all show a real commit in
  `git log -1 -- <file>` (`sweeper.ex`/`tenant_key.ex` specifically confirmed no
  longer untracked). ash_remote: `server/fields.ex`, `realtime/connection.ex` —
  both tracked, both landed in the "Phase 1 (B1, B2)" commit that opened this
  fix run. `git status --short lib/` clean in both repos (aside from this
  session's own in-progress work, itself committed per-task throughout). Every
  downstream retained-regression task and A0/R0 assumed this durability was
  already in place; that assumption held.
- **Severity**: Cross-cutting (data-loss guard, not a code fix)
- **Repo**: both
- **Source**: pass-3b §A commit-fragility; made a tracked preflight per pass-5
  review (the FINAL-only gate was tracked too late — retained-regression tasks
  reach it before FINAL closes)

## Why this is first

The entire partial second-plan implementation — including the index's **Cat A**
uncommitted fixed-in-tree items (B1's #27 half, L12 items 3/4/5/8, and docs-only
L13 item 4) and the untracked `tenant_key.ex` + `sweeper.ex` — exists **only in
the uncommitted working tree**. A `git checkout` or branch switch silently
reverts all of it, and with no committed regression tests yet, nothing catches
the backslide. Every retained-regression task assumes those Cat A fixes are
present; that assumption is only safe once they are committed. (Cat B
landed-but-untested items are already committed and are NOT commit-fragile — see
the index's canonical inventory.)

## Task

MDL and `../ash_remote` are **separate git repositories**
(`git rev-parse --show-toplevel` differs) — this is **two coordinated commits,
one per repo**, not a single commit spanning both trees (pass-6 review).

1. **MDL** (`/home/joba/sandbox/ash_multi_datalayer`): commit the uncommitted
   `lib/` state — at minimum `capability.ex`, `supervisor.ex`, `flush.ex`,
   `write.ex`, `enqueue.ex`, plus the untracked `tenant_key.ex` and `sweeper.ex`
   — on a work branch (not `main`).
2. **ash_remote** (`/home/joba/sandbox/ash_remote`): commit its uncommitted
   `lib/` state (incl. `server/fields.ex`, `realtime/connection.ex`) on a work
   branch.

Neither requires the work to be finished — each just freezes that repo's current
baseline so the "fixed-in-tree" labels are durable.

> The user has not yet asked to commit — if this preflight is picked up
> autonomously, confirm the branch/commit with them first, since committing is
> an outward-facing action.

## The skip path does NOT confer durability (loop-2 review)

A recorded _skip_ is a valid way to CLOSE this task, but it does **not** make
the Cat A fixes durable — the whole point of PRE. So skipping is not free: if
either repo is skipped, the downstream durability assumption is void, and the
Cat A items for that repo must instead be made durable another way before their
retained-regression tasks close. Concretely, on skip you MUST do one of: (a)
commit those specific Cat A files as part of each owning task's own fix commit,
or (b) reclassify them in the index inventory from "Cat A fixed-in-tree" to
"must re-implement" (they can no longer be assumed present). Do not close B1/L12
Cat-A regressions or A0/R0 on the strength of an unbacked skip.

## Done when

- [ ] **MDL** uncommitted `lib/` state committed on a work branch (untracked
      `tenant_key.ex` + `sweeper.ex` included), **or** skip recorded **with the
      (a)/(b) durability plan above**
- [ ] **ash_remote** uncommitted `lib/` state committed on a work branch
      (`fields.ex` #27 fix, `connection.ex` doc, etc.), **or** skip recorded
      **with the (a)/(b) durability plan above**
- [ ] Every Cat A item is durable — committed here, or committed by its owning
      task, or reclassified — before any retained-regression task or A0/R0 that
      depends on it closes
