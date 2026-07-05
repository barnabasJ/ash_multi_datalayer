# Review (pass 5): Orchestrator Extraction + LocalOutbox Plan

**Metadata:**

- Type: review
- Status: complete
- Created: 2026-07-05
- Subject:
  [docs/plans/orchestrator-extraction-and-local-outbox-plan.md](../plans/orchestrator-extraction-and-local-outbox-plan.md)
  (v4 — incorporates pass-4 P1–P3 and review-3 V1–V4)
- Prior reviews: review 1 (F1–F11), adversarial pass 1 (B/D), pass 2 (F1–F7),
  pass 3 (R1–R11, mine), review 2 (R1–R7), pass 4 (P1–P3, mine), review 3
  (V1–V4)
- Method: full re-read of v4; **source-level verification of the last two
  unverified load-bearing claims** — `job.conf.name` population and trigger-
  worker → action context threading — by extracting `oban-2.23.0.tar` and
  `ash_oban-0.8.10.tar` from the hex cache and reading the generated-worker +
  executor code directly.

## Verdict

**Ready to execute.** The named-instance mechanism was the last major technical
risk (it underpins the two-instance e2e, which underpins Phase 7's flagship
demo). I verified the two claims no prior pass had checked against the source,
and both hold — the mechanism is implementable exactly as specified. What
remains is two bookkeeping/wording nits. No substantive findings.

## Source-level verification (the value of this pass)

Prior passes established the named-instance *design* (MDL owns four enqueue
sites; worker-side resolution via `job.conf.name`) but the two load-bearing
facts underneath it — that `job.conf` is populated at worker dispatch, and that
the trigger worker threads the job into the action context — were asserted
(review-3 V1) or assumed, not verified. Both now checked against the packages:

### Claim 1 — `job.conf` is populated when `perform/1` runs: CONFIRMED

`lib/oban/queue/executor.ex:57-61`:

```elixir
def new(%Config{} = conf, %Job{} = job, opts \\ []) do
  ...
  job: %{job | conf: conf},     # ← conf injected into the job struct
```

The executor constructs the exec state with `job` updated to carry `conf`, and
`perform/1` (`executor.ex:144-145`) calls `worker.perform(job)` on that
conf-populated job. The `%Oban.Job{}` struct declares `conf` as a virtual
field (`lib/oban/job.ex:154`, `field :conf, :map, virtual: true`, typed
`Oban.Config.t() | nil` at `:108`); the executor is what lifts it from `nil`
to the running instance's `%Oban.Config{name: ...}`. So `job.conf.name` is the
Oban instance name, available in every worker `perform/1`. Review-3 V1's
assertion was correct.

### Claim 2 — the trigger worker passes the job into the flush action's context: CONFIRMED

`lib/ash_oban/transformers/define_schedulers.ex:1057-1060` (the generic-action
trigger worker — the flush's shape):

```elixir
|> Ash.ActionInput.set_context(
  AshOban.build_context(unquote(Macro.escape(trigger.shared_context)), job)
)
```

`AshOban.build_context/2` (`ash_oban.ex:785`) places `%{ash_oban: %{job: job}}`
into the action context (the `regular`/private side by default, `shared` if
`:job` is a shared-context key). So the flush action — and therefore
`LocalOutbox.Flush.run/2`, which the action delegates to — can read the
instance via `context[:ash_oban][:job].conf.name`. The job reaches the action.

### Bonus confirmation — no `worker_read_action` before the MDL-owned body

A latent risk in the establishment-point design: if ash_oban's generated worker
did a `worker_read_action` *before* calling the flush action, that read would
need the correct repo established earlier than Flush.run/2's first act (which
the plan makes the establishment point). Verified it does not apply to the
flush: `define_schedulers.ex:1014` dispatches the `:action` trigger type
through `work(..., :action, ..., _read_action, ...)` — `_read_action` is
**unused** for generic-action triggers. The perform body (`:1031-1065`) goes
straight to `Ash.run_action!` at `:1065` with no preceding read; the
`worker_read_action` re-check semantics (Phase 2 item 2) apply to the
update/destroy trigger shapes (`:1096+`), not the flush. So Flush.run/2's first
act genuinely is the first Ash call in the worker, and establishing
`put_dynamic_repo` + the instance name there is sound.

**Net:** the named-instance mechanism — immediate kick (caller process, via
instance plug/hook), chain continuation + retry re-trigger (worker process, via
`job.conf.name` threaded into action context), sweeper (MDL-owned, own config)
— is implementable as written. Phase 2 item 11's assertion ("enqueue from a
worker running under instance B routes to B, resolved via `job.conf.name`") is
testable against reality, not a hope.

## Incorporation confirmed (pass-4 P1–P3, review-3 V1–V4 — all in v4)

| Prior finding | Status in v4 |
|---|---|
| pass-4 P1 (four enqueue sites) | **Closed.** Phase 3 enumerates "one enqueue helper, four call sites" incl. the non-obvious chain-continuation in Flush.run/2 and retry re-trigger (plan:416-431); Phase 4 flush body cross-references it (plan:479-482). |
| pass-4 P2 (ADR "no scheduler" qualification) | **Closed** (plan:440-444). |
| pass-4 P3 (unique-job dedup under MDL insertion) | **Closed** — Phase 2 item 11 (plan:370-373). |
| review-3 V1 (per-process establishment, two missing points) | **Closed.** `put_dynamic_repo` per-process-not-inherited stated (plan:737-738); Oban worker via `job.conf.name` as flush body's first act (plan:742-744); caller-side via instance plug/hook setting both repo + Oban name (plan:739-742). |
| review-3 V2 (attribution) | **Closed** — ~97 credited to pass-3 R1, B2's 85 noted, ADR no longer called "stale" (plan:309-312); R3 parenthetical reworded (plan:572-573). |
| review-3 V3 (commit chain + count method) | **Closed** — `2aca728` added (plan:146); count method recorded (plan:148-150, 311-312). |

## Nits

### N1 (minor, bookkeeping) — metadata "Reviewed" list omits the two most recent passes

The plan's metadata (plan:14-24) lists five review series as "Reviewed (all
incorporated)": review 1, adversarial pass 1, pass 2, pass 3, review 2. It does
**not** list pass-4 (P1–P3) or review-3 (V1–V4), even though both are
incorporated in the body (cited inline at plan:373, 416-444, 479-482, 572-573,
737-748) and this pass confirms that incorporation. For a plan whose audit
trail is otherwise meticulous (every edit carries its review attribution), the
metadata's "all incorporated" claim is missing its two most recent inputs. Add
them so the claim is verifiable from the header alone.

### N2 (nit, wording) — "the flush worker's first act" conflates the generated worker with the MDL-owned action body

Phase 3 (plan:434-435) and Phase 7 (plan:742-744) say the instance
establishment is "the flush worker's first act (MDL owns the flush body)". The
flush *worker*'s `perform/1` is **generated by ash_oban** (`define_schedulers.ex`),
not owned by MDL; what MDL owns is the flush *action body* (`LocalOutbox.Flush.run/2`),
which the generated worker reaches via `Ash.run_action!`. The establishment
therefore lands in Flush.run/2's first act, not the worker's. The parenthetical
clarifies intent, but "worker's first act" could lead an implementer to try
injecting into the generated `perform/1` (not possible — it's generated) rather
than into Flush.run/2. This is verified to be merely wording: the generic-action
trigger does no read before the action (Claim 3 above), so Flush.run/2's first
act genuinely is the first Ash call, and establishing there is correct. Suggest
"the flush action body's first act" / "Flush.run/2's first act" in both spots.

## Items explicitly not flagged

- The named-instance mechanism is source-verified end to end (Claims 1–3). No
  prior pass had done this; it is the remaining de-risk and it passes.
- The four-enqueue-site enumeration (pass-4 P1) is complete and correct: the
  caller-side sites (immediate kick, retry-from-LiveView) resolve via the
  instance plug/hook; the worker-side sites (chain continuation, retry-from-
  worker) resolve via `job.conf.name`; the sweeper is MDL-owned. Non-Ash-HTTP
  callers that write+enqueue (none in v1 — refresh/hydrate don't enqueue) would
  need the instance established, but no such path exists in the current design.
- `await/2` is instance-agnostic (it watches the entry resource's notifier, not
  the Oban queue), so two-instance await is sound without extra mechanism.
- The phase graph, gate discipline, and the ADR/RFC/plan three-way consistency
  are unchanged and coherent after the v4 edits. No new sequencing or
  consistency issues introduced.

## Recommendation

Address N1 (metadata completeness) and N2 (wording) as a single small edit;
neither blocks execution. **Phase 1 may branch.** The plan has cleared seven
review passes and the deepest technical claim (the named-instance mechanism)
is now source-verified rather than asserted — the residual risk surface is
genuinely the Phase 2 spike items, which is where it should be.

---

**Last Updated**: 2026-07-05
