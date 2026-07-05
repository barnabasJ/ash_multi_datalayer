# Review (pass 4): Orchestrator Extraction + LocalOutbox Plan

**Metadata:**

- Type: review
- Status: complete
- Created: 2026-07-05
- Subject:
  [docs/plans/orchestrator-extraction-and-local-outbox-plan.md](../plans/orchestrator-extraction-and-local-outbox-plan.md)
  (v3 — incorporates pass-3 R1–R11 and review-2 R1–R7)
- Prior reviews: pass 1 (F1–F11), adversarial pass 1 (B/D), pass 2 (F1–F7),
  pass 3 (R1–R11, mine), review 2 (R1–R7)
- Method: full re-read of v3; the load-bearing **named-Oban-instance** claim
  (review-2 R1) was verified by extracting `ash_oban-0.8.10.tar` from the hex
  cache and reading every enqueue call site; incorporation of pass-3 and
  review-2 findings re-checked against the edited text.

## Verdict

v3 is in strong shape. Every pass-3 and review-2 finding is genuinely
incorporated (verified item-by-item below), and the response to review-2 R1 —
"MDL owns its Oban touchpoints" — is the **correct** architectural call: I
confirmed ash_oban 0.8.10 has no instance hook anywhere on the enqueue side
(`run_trigger/3`→`Oban.insert!/1` at `ash_oban.ex:922`; `schedule/3`→`:855,861`;
`run_triggers/3`→`:940,943`; generated schedulers `define_schedulers.ex:176,192`;
generated action workers `define_action_workers.ex:97`). The one substantive
new finding (P1) is a *consequence* of that correct decision: it names a third
enqueue site the mechanism doesn't yet cover. The rest is calibration.

## Incorporation verified (pass-3 R1–R11, all closed)

| Pass-3 | Status in v3 |
|---|---|
| R1 facts-stale / Phase 0 | **Closed.** Facts now "fully landed ... Phase 0's gate is satisfiable now" (plan:143-151); Phase 0 gate hardened to committed + `forget!` + `INTEGRATION=1` (plan:230-234). |
| R2 hot-path cost of serving-degradation check | **Closed.** Phase 4a adds the O(query-shape) cost bound + a budget gate measured vs today's `covers?` (plan:559-566, 580). |
| R3 lock-branch ambiguity | **Closed.** Decision recorded: "resurrected, not removed" with rationale (plan:539-544, gate at 577-579). |
| R4 Goal 2b scope acknowledgement | **Closed.** Goal 2b marked "a v2 scope addition, per plan-review pass 3 R4" (plan:38-41). |
| R5 DSL-key/gate conflict (the blocker) | **Closed.** Phase 1 retains section-level aliases forwarding into opts; alias removal + declaration/test updates deferred to Phase 4a (plan:258-268, 581). |
| R6 supervisor discovery | **Closed.** Mechanism specified: `otp_app:`/`resources:` opts; ProvenCoverage keeps lazy start; eager only for hydration (plan:289-299). |
| R7 merge non-goal wording | **Closed.** Rewritten to "Library-side/automatic merging" with app-mediated `rebase/2` explicitly allowed (plan:193-201). |
| R8 co-commit/crash test split | **Closed.** Two named tests (a) co-commit atomicity, (b) post-commit kick recovery (plan:494-499). |
| R9 generator idempotency / runtime wiring | **Closed.** Phase 3 gate adds idempotent re-run, boot-against-temp-SQLite, queue/trigger match (plan:420-425). |
| R10 `seq` preference order | **Closed.** Integer PK first; `max(seq)+1` conditional on item-8 serialization (plan:351-356). |
| D3/D4/D6/D7/D8 carry-forwards | **Closed.** Goal 3 degraded-outcome caveat (plan:53-59); funneling mapping table in Phase 1 commit (plan:310-314); funneling-scope "ProvenCoverage only at Phase 1" (plan:282-288); Phase 6 namespace contingency note (plan:712-715); payload types per item 10 (plan:381-384). |

## Incorporation verified (review-2 R1–R7, all closed)

| Review-2 | Status in v3 |
|---|---|
| R1 named-instance gap | **Closed (mechanism).** Facts record the hardcoded default (plan:131-137); Phase 2 item 11 is the end-to-end spike (plan:360-366); Phase 3 specifies MDL-owned insertion + `scheduler_cron false` + MDL sweep worker (plan:402-414). **See P1 for an uncovered consequence.** |
| R2 repo-selection hook | **Closed.** Phase 7 names `put_dynamic_repo` per instance process tree incl. MDL's internal call sites (plan:700-710). |
| R3 facts "two components" contradiction | **Closed** (plan:162-166). |
| R4 Capability precedent overstated | **Closed** (plan:556-559). |
| R5 `{:atomic,_}` wildcard | **Closed** (plan:121-122). |
| R6 transitional notes | **Closed** (plan:300-304, 478-481). |
| R7 multitenancy verifier | **Closed** (plan:483-486). |

## New finding

### P1 (major) — the flush body's chain-continuation kick is an instance-unaware enqueue the named-instance mechanism doesn't cover

Review-2 R1's response (Phase 3, plan:406-414) names **two** enqueue sites MDL
owns: the *immediate kick* (write path → `Oban.insert(instance, job)`) and the
*sweeper* (MDL-owned sweep worker in the instance cron, `scheduler_cron false`
on the trigger). It then says "MDL bypasses only its insertion calls" and
"ash_oban still provides the worker/trigger/action machinery."

There is a **third** enqueue site, and it is the subtle one because it lives
*inside library code*, not on the write path or in the scheduler:

- **Chain continuation.** The RFC's flush success path (rfc:191-204) — and
  Phase 4's own deliverable (plan:446-449) — specifies: *"success deletes entry
  + kicks next chain entry."* That kick is `run_trigger`. The flush body is
  library code (`LocalOutbox.Flush.run/2`, per plan:399-401). A bare
  `AshOban.run_trigger/3` there enqueues into the **default global `Oban`**
  (verified: `ash_oban.ex:922`), not instance B. In a two-instance deployment
  the next-in-chain job silently lands in the wrong queue → per-PK FIFO stalls
  or routes against the wrong repo. This is exactly the class review-2 R2
  flagged for *repo* selection ("MDL's internal call sites ... the non-obvious
  part") — the same blind spot applies to *Oban insertion*, and the chain-kick
  is the instance that bites.
- **Retry re-trigger.** `retry/1` is specified as "parked → pending +
  re-trigger" (plan:453). Same issue: the re-trigger is an enqueue from inside
  the resolution path.

The plan's Phase 3 mechanism should name these explicitly. Concretely:
`LocalOutbox.Flush.run/2`'s success path and the `retry` action must use the
**MDL instance-aware enqueue** (the same `Oban.insert(instance, job)` helper
the immediate kick uses), not `AshOban.run_trigger/3`. This is not a design
defect — the mechanism already exists (Phase 3 builds the helper for the
immediate kick); it is a completeness gap in *which call sites use it*.

**Why it matters even for single-instance deployments:** even with one Oban
instance, routing the chain-kick through `AshOban.run_trigger/3` vs the MDL
helper is a behavioural difference only if the helper does anything beyond
`Oban.insert/2` (e.g., telemetry, unique-job args shaping). Pinning all
flush-adjacent enqueues to one MDL-owned path keeps the telemetry surface and
the unique-job behaviour uniform. So the fix is the same regardless of
instance count: one MDL enqueue helper, used by (a) immediate kick, (b)
sweeper, (c) chain continuation, (d) retry re-trigger.

**Severity:** major, not blocking — Phase 4's per-PK FIFO gate (plan:493) and
Phase 2 item 11 would both catch the stall empirically. But naming it now
saves the implementer of `Flush.run/2` from reaching for `AshOban.run_trigger/3`
by default (the obvious call) and discovering the routing bug in integration.

**Recommended edit:** extend Phase 3's `oban_instance` deliverable
(plan:402-414) to enumerate *all four* enqueue sites that route through the
MDL-owned helper, with the chain-continuation and retry-re-trigger sites
called out as the non-obvious ones (library-internal, not write-path). One
sentence in Phase 4's flush-body deliverable (plan:446-449) cross-referencing
the helper closes it.

## Calibration / minor

### P2 (moderate) — the MDL-owned sweep worker partially walks back the sync-state ADR's "no scheduler" claim

The sync-state ADR lists as a positive consequence (adr:62-63): *"the library
ships no queue, no drainer, and no scheduler of its own."* The named-instance
workaround (review-2 R1) forces MDL to ship a sweep worker that discovers
pending entries and enqueues them — i.e., a scheduler of pending-entry
discovery, however thin (it's "query the outbox resource + insert jobs", not
a full reimplementation of ash_oban's `where`/`sort`/`stream_with`/unique-dedup).
That is a real, if minor, qualification of one of the ADR's selling points.
The tradeoff is clearly worth it (named instances are required for the
two-instance e2e, which is required for the cross-client demo), but the ADR's
"no scheduler" line is now conditional on "single Oban instance". **Recommend:**
one sentence in Phase 3 acknowledging that the named-instance path ships a
thin sweep worker, qualifying the ADR's framing, so the ADR's "no scheduler"
claim isn't inherited unchanged into v1 release notes.

### P3 (minor) — Phase 2 item 11 should re-assert unique-job dedup under MDL-owned insertion

Phase 2 item 6 asserts unique-job behaviour for `run_trigger` dedup under the
default instance. Item 11 (the named-instance spike) proves enqueue + cron
sweep into instance B but does not mention re-asserting unique-job dedup under
the MDL-owned `Oban.insert(instance, GeneratedWorker.new(args))` path. The
`unique` config rides on the worker struct (from the trigger definition), so
`GeneratedWorker.new(args)` should carry it and `Oban.insert/2` should enforce
it — *should*. This is precisely the class of third-party assumption item 11
exists to de-risk. Add one clause: "unique-job dedup holds under the MDL-owned
insertion path (item 6 generalised)."

## Items explicitly not flagged

- The named-instance discovery and response (review-2 R1 → Phase 3 mechanism)
  is the right call and well-verified. P1 is a completeness gap in its call-site
  enumeration, not a defect in the approach.
- The two-instance repo-selection hook (Phase 7, plan:700-710) correctly
  identifies MDL's internal call sites (flush/refresh/hydrate) as the
  non-obvious process-tree boundary for `put_dynamic_repo` — this is the same
  class as P1 and was already named for *repo*; P1 only asks for the same
  treatment on the *Oban* side.
- All ash_sqlite/ash_oban capability and API facts in v3 now match the package
  sources (the `{:atomic,_}` wildcard was the last loose thread; fixed at
  plan:121-122).
- The phase graph, gate discipline, funneling auditability, DSL-alias
  transitional plan, and the honesty gates (Phase 5 benchmark, Phase 4a
  behavioural deltas asserted not discovered) are all coherent after the v3
  edits. No new sequencing or gate inconsistencies introduced.
- Non-goals (post-R7 reword) are now internally consistent with Phase 7's merge
  UI.

## Recommended edits, in priority order

1. **(P1)** Extend Phase 3's `oban_instance` deliverable to enumerate all four
   enqueue sites through the MDL-owned helper (immediate kick, sweeper, **chain
   continuation in `Flush.run/2`**, **retry re-trigger**); cross-reference from
   Phase 4's flush-body deliverable.
2. **(P2)** Acknowledge in Phase 3 that the named-instance path ships a thin
   sweep worker, qualifying the sync-state ADR's "no scheduler" claim.
3. **(P3)** Add a unique-job-dedup clause to Phase 2 item 11.

The plan is ready to execute Phase 1 once P1 is addressed; P1 is the only item
that could cause rework if left to integration discovery.

---

**Last Updated**: 2026-07-05
