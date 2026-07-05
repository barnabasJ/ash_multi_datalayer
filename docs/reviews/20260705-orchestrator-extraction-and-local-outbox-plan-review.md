# Review: Orchestrator Extraction + LocalOutbox Plan

**Metadata:**

- Type: review
- Status: complete
- Created: 2026-07-05
- Subject:
  [docs/plans/orchestrator-extraction-and-local-outbox-plan.md](../plans/orchestrator-extraction-and-local-outbox-plan.md)
- Method: plan read + four parallel verification passes (MDL codebase claims,
  hex-cache dependency claims, design-doc consistency, sibling-repo claims) plus
  an internal-consistency pass on the phase graph and gates.

## Verdict

The plan is in good shape: the phase graph is coherent, the gates are real and
checkable, the RFC/ADR cross-references are accurate (the plan's Phase 4
checklist matches the LocalOutbox RFC item for item), and nearly every recorded
"fact" about the hex cache checked out against package sources. Two findings are
substantive enough to warrant plan edits before Phase 2/4 are executed (F1, F3);
the rest are scope-accuracy corrections and bookkeeping.

## Findings

### F1 (major) — the co-commit gate as specced can never fire on the flagship stack

Phase 4's write path: _"co-commit transaction when same repo +
`can?(:transact)`, detected once at verify time."_ ash*sqlite 0.2.17 — the
pinned local layer for the flagship's `Todo`/`TodoList` — hard-codes `can?(*,
:transact), do: false`(and`can?(_, {:lock, _}), do:
false`) in `ash_sqlite-0.2.17/lib/data_layer.ex:448-450`. So on exactly the
stack the whole arc showcases ("one SQLite file holding data + outbox + jobs"),
the capability check fails and the co-commit path never activates. The local
write and the outbox enqueue would then sit in the RFC's own worst crash window
("a crash between steps 1 and 2 loses the replication intent").

Phase 2 item 8 would eventually trip over this, but it is knowable now and it
invalidates the spec text, not just an assumption. The detection predicate needs
to be something like _same Ecto repo → wrap in `Repo.transaction/1` directly_
(bypassing the Ash data-layer capability), or ash_sqlite needs `transact`
support upstream. Recommended plan edits:

- Rewrite the Phase 4 co-commit bullet to not gate on `can?(:transact)`.
- Reframe Phase 2 item 8 from "prove it works" to "prove the
  raw-`Repo.transaction` wrapper works for two Ash writes on an
  ash_sqlite-backed repo, given `can?(:transact) == false`".
- Note the same fact where the RFC's durability matrix says "co-commit
  recommended".

(Related, benign: ash_oban's capability checks — verified present at
`define_schedulers.ex:442,467` — will correctly skip `FOR UPDATE` on this stack,
as the plan's facts section says.)

### F2 (major) — Phase 4 bundles a shell data-path change into the phase whose objective is "no shell data-path changes"

Phase 4's objective is the ADR's validation criterion — LocalOutbox lands
_"without modifying the shell's data-path code"_ — yet one of Phase 4's own
deliverables is the **shell-level** `read_from:` context bypass. The plan's
reasoning for putting it in Phase 4 rather than Phase 1 is sound (nothing new
may ride the pure-refactor gate), but landing it inside Phase 4 means the Phase
4 diff touches the shell's read path, and the "seam is real" demonstration is no
longer a clean diff. Recommendation: split it out as its own step (Phase 4a or a
separate commit series with its own gate) so the LocalOutbox strategy diff
proves the criterion by inspection. Note the ADR places `read_from:` under "what
stays in the shell", so a standalone shell increment is also truer to the ADR's
structure.

### F3 (major) — Phase 7's two-client-instance e2e has an unaddressed architecture problem

The e2e calls for _"two client instances, different users"_ where _"A's write
refreshes B's sqlite"_ — i.e. two instances of the `todo_client` OTP app in one
BEAM, each with its own SQLite file, its own outbox, its own Oban instance, its
own endpoint and PubSub. One BEAM cannot boot the same OTP app twice; this
requires parameterizing the client app (dynamic repos or two configured repo
modules, two named Oban instances, two endpoints on different ports) or running
two nodes. Consequences:

- Open question 4 (`oban_instance` opt, "default `Oban`, opt added in Phase 3 if
  the skeleton shows it's needed") is **not optional** under this e2e: two Oban
  instances over two SQLite files cannot both be named `Oban`. The opt should be
  pulled into Phase 3's committed scope.
- The plan should state the two-instance mechanism explicitly (the existing
  precedent — the ash_remote_cache example's e2e — runs one client app, so there
  is no precedent to lean on).

### F4 (moderate) — Phase 6's dissolution scope undercounts ash_remote_cache

The plan describes the library as "~480 lines: the notifier + lifecycle guard".
Line count verified (483), but `lib/` has **five** modules, and the largest is
neither of the two named: `CacheLayer` (149 lines), plus `AshRemoteCache.Info`
and the top-level `AshRemoteCache` module carrying `forget!/3`, `notifiers/1`,
`ordered?/1`, `not_found?/1`. The C4 fold-back retires `CacheLayer.evict!/3`,
`forget!/3`, and evict-on-destroy, and the before-image point-query
(`CacheLayer.fetch/3`) moves into ProvenCoverage's `handle_external_change/2` —
all accounted for. Not accounted for:

- `notifiers/1` / `ordered?/1` — the notifier-ordering helper and its guarantee
  (RealtimeBridge must run _after_ invalidation). Where do users get this once
  the utilities live in ash_remote?
- `Info` (eligibility check) and `not_found?/1` — retire, move, or absorb?

Phase 6 should enumerate the destination (or retirement) of all five modules,
not two.

### F5 (moderate) — Phase 7's "re-scaffold" is a rewrite, and the framing hides a decision

The plan calls the ash_remote_cache example apps "real Phoenix apps" being
"built out". They are **hand-rolled minimal Phoenix apps**: a single
hand-written `endpoint.ex` each, no `*_web` namespace, no assets, no telemetry,
no gettext. Re-scaffolding via `phx.new --no-assets` and re-hosting the existing
resources, auth, routers, and three test suites is a scaffold rewrite plus full
wiring migration — a real decision, not a default: the hand-rolled shape has
precedent (MDL's own example) and is trivially offline-safe, while full phx.new
buys the conventional structure the flagship presumably wants. The plan should
say which and why.

Related gap: `--no-assets` means no bundler, and the sync-center/conflict UI is
LiveView — the plan records the hand-rolled **CSS** story but not the **JS** one
(LiveSocket). phoenix/phoenix_live_view ship servable prebuilt JS and the
existing todo_client Live UI already solves this; carry that note into Phase 7
so it isn't rediscovered.

### F6 (moderate) — Phase 1's callback enumeration is incomplete relative to the behaviour ADR

The ADR's behaviour defines **13** callbacks; Phase 1 lists 11, omitting
`handle_external_change/2` and `handle_external_gap/2` (optional in the ADR; the
plan first mentions them in Phase 4). Since Phase 1 builds the
`ValidateOrchestrator` verifier and claims "the behaviour seam per the ADR",
either define the two inbound callbacks in Phase 1 (as optional callbacks with
no implementations yet) or state the deferral explicitly — otherwise the
behaviour module gets modified again in Phase 4, and the Phase 1 "seam complete"
framing is quietly false. Also minor: the ADR marks `validate_opts/2`,
`child_specs/1`, **and `run_aggregate_query/3`** as optional; the plan annotates
only `child_specs/1`.

### F7 (moderate) — `seq` "autoincrement" on SQLite needs a design answer, and the dropped RFC question hid it

Phase 3 injects `seq` as an autoincrement attribute on `OutboxEntry`. In SQLite
only an `INTEGER PRIMARY KEY` column autoincrements; a non-PK autoincrement
column is not a thing ecto_sqlite3 can just emit. If the resource keeps a uuid
`id` PK, `seq` needs another source — e.g. make `seq` the integer PK/rowid, or
assign `max(seq)+1` inside the enqueue transaction (which loops back to F1's
transaction question). The RFC's OQ4 ("`seq` on non-SQL outboxes") was dropped
as moot, but the SQL-on-SQLite variant of the same question is live.
Recommendation: add this as an explicit Phase 2 spike item (it fits between
items 1 and 9) rather than discovering it inside Phase 3.

### F8 (minor) — Phase 0 gate status: prerequisite plan is only partially landed

For the record at review time: fix-plan Phases 0–2 (regression harness + C1/C2)
are committed (`6b5ab7c`); C3/C4 are in the uncommitted working tree (+520/−98
across `coverage.ex`, `invalidation.ex`, `data_layer.ex`, `write_dispatch.ex`,
race tests); M1 and hardening are pending. The gate is correctly specified and
correctly not yet satisfied. One facts-section correction:
`test/support/blocking_layer.ex` **already exists** (landed with the Phase 0
harness) — Phase 4's "extend test/support/ per the fix plan's blocking_layer.ex"
reads as future-tense and should read as "extend the existing blocking layer".

### F9 (minor) — stale/fragile facts in the "facts" section

- `data_layer.ex` is 996 lines at HEAD (1166 in the working tree), not 965 — and
  it will drift further as C3/C4 land. Drop the exact number; the decision-tree
  description itself verified precisely (dispatch tree at `run_query/2`,
  fold/join split, remainder/merged/source reads all where claimed).
- "evict-on-destroy machinery returns to MDL" understates the C4 fold-back: the
  fix plan (per the C4 addendum's update-variant) lands evict-on-destroy **and**
  evict-on-update plus the reconcile pass. Phase 6 should retire the stopgap
  against that broader surface.
- ash_sqlite has **no explicit keyset capability flag** — keyset streaming works
  via Ash-level filter+sort+limit. Phase 2 item 7's `:full_read` fallback is
  well-placed; just don't look for a capability to check.
- The RFC's OQ3 says payload encoding is a "Phase-3 spike deliverable"; the plan
  (correctly per its own numbering) routes it to Phase 2 item 9. Fix the RFC's
  stale label.

### F10 (minor) — cross-repo notes for Phase 6

- MDL is **already not a dependency** of ash_remote (no mix.exs/mix.lock entry)
  — the Phase 6 work is _adding_ it as `optional: true`, not loosening an
  existing hard dep. ash_remote does hard-reference the module name
  (`@remote_layers` includes `AshMultiDatalayer.DataLayer` in
  `expressions/remote.ex:40`), which is fine without the dep but is an existing
  precedent for the runtime-checked pattern.
- The "C4 fold-back agreement" is recorded only in MDL's docs (the C4 addendum +
  fix plan); nothing in the ash_remote_cache repo marks `CacheLayer.evict!/3` /
  `forget!/3` / evict-on-destroy as stopgaps-to-retire — their moduledocs
  present them as permanent fixes. Since Phase 6 executes in that repo (likely a
  fresh context), leave a breadcrumb there pointing at the addendum's retirement
  list.
- ash_remote_cache and its example pin all three sibling repos as **path deps**
  (no git refs), so Phase 6/7 pick up MDL/ash_remote changes live — no pin-bump
  step exists or is needed there. (MDL's own example is the one with the git-ref
  pin, via mix.lock.)

### F11 (observation) — Phase 2 item 5 is already answerable

ash_oban 0.8.10 has a first-class snooze path: raising/returning
`AshOban.Errors.SnoozeJob` (`lib/errors/snooze_job.ex`) maps to
`{:snooze, seconds}` in `check_for_oban_return` (`ash_oban.ex:1326`), and Oban's
`snooze_job` both re-schedules and increments `max_attempts`
(`engines/basic.ex:263`, Lite delegates) — the zero-budget-burn claim is exact.
The custom-worker-wrapper fallback in item 5 won't be needed; the spike item can
shrink to a confirmation test.

## Facts verified without issue

- Hex cache: all nine packages present at the pinned versions (oban 2.23.0,
  ash_oban 0.8.10, ash_sqlite 0.2.17, ecto_sqlite3 0.22.0, exqlite 0.36.0,
  igniter 0.8.2, phx_new 1.8.5, oban_web 2.12.5, oban_met 1.2.0); ash up to
  3.29.3.
- oban_web 2.12.5: dep requirements exactly as recorded; assets pre-built and
  self-contained (`priv/static/app.{css,js}` read at compile time, no node
  step); mounts via `import Oban.Web.Router` + `oban_dashboard`.
- Oban Lite: `fetch_unique/2` implemented (`engines/lite.ex:322`) — unique jobs
  work on Lite.
- ash_oban 0.8.10: all 15 recorded trigger DSL options present with the claimed
  types; `run_trigger/3`, `schedule/3`, `schedule_and_run_triggers/2` all exist;
  igniter install task ships at `lib/mix/tasks/ash_oban.install.ex`; capability
  checks are `Ash.DataLayer.data_layer_can?/2` on `:transact` /
  `{:lock, :for_update}` as described.
- MDL code shape: `WriteDispatch`, `Backfill`, `Coverage.*`, `ValueMerge`,
  `Delegate`, `SqlPassthrough`, `Capability`, `KillSwitch`, `Telemetry`,
  `Migration` all present; six verifiers; ledger is raw ETS keyed
  `{tenant, entry_id}` with `loaded_at` LRU and `Info.ledger_max_entries/1` cap;
  storage primitives `insert/entries/drop/reset/size/touch` exist; all nine
  strategy-specific DSL options are in the section schema with Info accessors;
  Supervisor → DynamicSupervisor (`TableSupervisor`) → per-resource `TableOwner`
  as described; `mix ash_multi_datalayer.inspect` exists; nothing named
  `Orchestrator` exists in `lib/` yet.
- Design docs: all eight referenced docs exist; Phase 4's checklist matches the
  LocalOutbox RFC's API surface, conflict-detection modes, dirty-chain rule,
  kill-switch write-through, and per-action targeting item for item; the
  stacked-orchestrators RFC is marked exploratory/post-arc and its funneling
  note matches Phase 1's; the fix plan defines C1–C4/M1 and the acceptance gates
  the plan's Phase 0 cites; the phase dependency statement is coherent (Phase
  6→1 and 7→1 hold transitively; Phase 7 correctly does not need benchmark-gated
  Phase 5).
- ash_remote_cache: InvalidationNotifier before-image recovery →
  `Invalidation.on_write/4`, LifecycleGuard on `:resubscribed`/`:join_denied` →
  `drop_all`, the compile-time-literal `notifiers:` gotcha in the README, and
  the example's auth/realtime/ counting-router/test-suite inventory all
  verified; `assignee_id`/ `tag_ids` absent today as Phase 7 assumes.

## Suggested plan edits, in one list

1. Rewrite the Phase 4 co-commit predicate (F1) and reframe Phase 2 item 8
   around `can?(:transact) == false` on ash_sqlite.
2. Split `read_from:`/`write_through:` shell work out of Phase 4 (F2).
3. Specify the Phase 7 two-instance mechanism; move `oban_instance` into Phase 3
   committed scope (F3).
4. Enumerate all five ash_remote_cache modules' destinations in Phase 6 (F4);
   leave a retirement breadcrumb in that repo (F10).
5. Decide and record hand-rolled vs phx.new for the Phase 7 apps; add the
   LiveView-JS-without-bundler note (F5).
6. Add the two inbound callbacks to Phase 1's behaviour definition or an
   explicit deferral note (F6).
7. Add a `seq`-on-SQLite spike item to Phase 2 (F7).
8. Facts-section touch-ups: line count, blocking_layer tense, evict-on-update
   wording, keyset-capability nuance, RFC OQ3 label (F8, F9); shrink Phase 2
   item 5 to a confirmation test (F11).

---

**Last Updated**: 2026-07-05
