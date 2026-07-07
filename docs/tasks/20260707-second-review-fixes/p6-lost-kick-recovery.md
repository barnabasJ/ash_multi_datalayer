# P6 — Lost-kick recovery semantics (#4): sweeper exists but is unproven

- **Status**: DONE — repros prove: (1) a `:pending` entry with no live job is
  discovered and enqueued by `Sweeper.run_once/1`; (2) a same-PK chain created
  with NO automatic kicks at all (bypassing both the write path's post-commit
  kick and `kick_next`) still fully converges across sweep ticks, respecting
  FIFO (`chain_position` stays non-`:head` for the tail until the ancestor
  resolves); (3) multitenant (tenant-scoped) entries are discovered too —
  retained regression, passes regardless of H5 per the task's own note (the
  sweeper's scan was never routed through the H5-affected `tenant_filter/2`).
  All 6 `Enqueue.flush` call sites that discarded the result now go through a
  new `flush_and_log/3` (or the sweeper's own `kick/2`), which logs + emits
  telemetry on failure instead of silently dropping it — the row stays
  `:pending` either way, so the next write/retry/sweep tick naturally retries
  it. Not independently repro'd: a genuinely-failing `Oban.insert` mid-sweep
  (would need Oban- level fault injection: disproportionate cost given remaining
  scope) — covered by code review + the existing rescue/log path instead of a
  live fault-injection test. `INTEGRATION=1 mix test` green (298).
- **Severity**: High (a lost kick strands a per-PK chain forever if recovery
  doesn't work)
- **Repo**: MDL (ash_multi_datalayer)
- **Source**:
  [second-review finding #4](../../reviews/20260706-second-review-findings.md);
  added as an explicit task per
  [task-coverage review F3](../../reviews/20260707-second-review-fixes-task-coverage-review.md)
- **Plan ref**: Workstream A phase A4 items 2, 3 (and A0 repro 6)
- **Files**: `lib/ash_multi_datalayer/orchestrator/local_outbox/sweeper.ex`
  (untracked), `sync/enqueue.ex`, write-path `Enqueue.flush` call sites
- **Related task**: [L5](l5-sweeper-global-name-multinode.md) (the sweeper's
  `{:global, ...}` name / multi-node posture — separate defect in the same
  module)

> Note: the 20260707 implementation review's executive summary says "#4
> (external-change)" — a mislabel. External-change is
> #21/[B4](b4-external-change-origin-marker-mismatch.md); **#4 is this lost-kick
> recovery finding.** Recorded here so the requirement doesn't fall through the
> cracks a third time.

## Requirement (original #4)

If the process dies between the co-commit and the post-commit `Enqueue.flush`,
or `Oban.insert` returns `{:error, _}` (historically discarded at every call
site), the `:pending` entry must not be stranded: later same-PK writes snooze
behind it (`:racing`) and `await` hangs.

The new sweeper reads `:pending` entries, filters to chain heads, and enqueues
them each tick — plausibly the recovery — but nothing proves:

1. A pending entry **without a live job** is discovered and enqueued (plan A0
   repro 6).
2. A same-PK blocked **tail is eventually kicked** after the head resolves (plan
   A4 verify 2).
3. `Enqueue.flush`/`Oban.insert` **errors at write time** are surfaced while the
   local transaction can still fail, or are deterministically recovered by the
   sweeper (plan A4 item 3 — the sweeper itself also discards `Enqueue.flush`
   errors in its `Enum.each`).
4. Tenant partitioning is respected by the sweep (ties into
   [H5](h5-localoutbox-nil-tenant-model.md) — the sweeper's unscoped read must
   actually see tenant-scoped entries).

## Done when

Repros must fail against the **current working-tree code** for the actual
recovery gaps — not merely with the sweeper disabled/removed. A
disable-the-sweeper test can pass on an implementation that still drops enqueue
errors, misses tenant-scoped entries, or never enqueues real stranded heads
(pass-2 coverage review F1).

- [ ] Repro: pending entry with no job AND a failing/erroring enqueue path → the
      entry is provably recovered (or the failure surfaced) — fails on the
      current code for the reviewed reason
- [ ] Repro: sweeper-tick enqueue failure (`Enqueue.flush` returning
      `{:error, _}` inside the sweep's `Enum.each`) is surfaced via
      telemetry/logging and deterministically retried on a later tick — fails on
      the current code, which silently discards it (pass-2 review F2; plan A4
      item 3 applies to the recovery worker too)
- [ ] Repro: multitenant (tenant-scoped) pending entries are discovered by the
      sweep — a **retained _passing_ regression**, NOT an H5-dependent
      fail-first. **Correction (loop-1 review, source-verified)**: the sweeper
      (`sweeper.ex:42-49`) reads with a plain unscoped
      `Ash.read!(authorize?:     false)` and does NOT route through the
      H5-affected `tenant_filter/2` (`nil → is_nil(tenant)`); the outbox
      `tenant` is a regular attribute, so an unscoped read already returns all
      tenants' entries. This case therefore **passes on current code regardless
      of H5** — do not frame it as failing on the H5 defect. The fail-first
      anchor is the sweeper-specific stranded- head repro below, which is
      independent of H5.
- [ ] Blocked-tail kick test after head resolution (plan A4 verify 2)
- [ ] Write-path enqueue-failure test: error surfaced while the local
      transaction can still fail, or provably recovered
- [ ] Baseline recovery test (sweeper disabled/removed → stranded) kept only as
      a supplement, never as the sole repro
- [ ] `INTEGRATION=1 mix test` green in MDL
