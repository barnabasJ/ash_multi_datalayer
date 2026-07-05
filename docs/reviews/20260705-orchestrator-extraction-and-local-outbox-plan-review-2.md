# Review 2: Orchestrator Extraction + LocalOutbox Plan (revised)

**Metadata:**

- Type: review
- Status: complete
- Created: 2026-07-05
- Subject:
  [docs/plans/orchestrator-extraction-and-local-outbox-plan.md](../plans/orchestrator-extraction-and-local-outbox-plan.md)
  (revision incorporating review-1 F1–F11)
- Prior review:
  [review 1](./20260705-orchestrator-extraction-and-local-outbox-plan-review.md)
- Method: full re-read + two verification passes on the revision's **new**
  factual claims (ash_sqlite capability surface, ash_oban instance support,
  dynamic-repo mechanics in the hex cache; N10/M3/shell-`can?` claims in the MDL
  codebase), plus an incorporation check of all eleven prior findings.

## Verdict

The revision is a real improvement: F1, F2, F5–F9, F10, and F11 are cleanly
incorporated, and every new factual claim backing Phase 4a **verified against
the code** — the `:transact` intersection really does contradict
`transaction/4`'s authority-only delegation, N10's dead lock branch and M3's
`KeyError :__ash_bindings__` crash are quoted accurately, and the ash_sqlite
capability facts match the package source clause for clause. But the F3 fix has
a hole the plan couldn't have known without checking the package: **ash_oban
0.8.10 cannot enqueue into a named Oban instance**, so the newly-committed
`oban_instance` option is not implementable by threading an option through
ash_oban's public API (R1). One residual from F3/F4 each, and a few calibration
nits, round out the list.

## New findings

### R1 (major) — ash_oban 0.8.10 hardcodes the default `Oban` instance on every enqueue path

The revision commits `oban_instance` to Phase 3 scope with "everything that
touches Oban (`run_trigger`, pause/resume, queue introspection) threads it".
Verified against the package source: there is **no instance hook on the enqueue
side anywhere in ash_oban 0.8.10**:

- `run_trigger/3` (`ash_oban.ex:922`), `schedule/3` (`:855,861`), and
  `run_triggers/3` (`:940,943`) all call bare `Oban.insert!/1` /
  `Oban.insert_all/1` — always the default global `Oban`.
- The generated schedulers and action workers do the same
  (`transformers/define_schedulers.ex:176,192`, `define_action_workers.ex:97`).
  So even a `scheduler_cron` sweep running _inside_ instance B's cron plugin
  would insert its trigger jobs into instance A's (default) queue — wrong repo,
  silently.
- No trigger/DSL option, no `config :ash_oban, :oban` key. The single `:oban`
  opt that exists is on `schedule_and_run_triggers/2` and applies only to
  `Oban.drain_queue/2` (`ash_oban.ex:1507-1519`).

This hits more than the two-instance e2e: the **sweeper-recovery story in Phase
4's gate** (crash between local write and `run_trigger` kick → cron sweep picks
the entry up) rides the generated scheduler, which is exactly the code that
can't target a named instance.

Options, roughly in order of preference:

1. **MDL owns its Oban touchpoints.** The kick path builds the job directly —
   `GeneratedWorker.new(args) |> then(&Oban.insert(instance, &1))` (the worker
   module name is known: Phase 3 already mandates `worker_module_name`) — and
   the sweep is an MDL-owned worker registered in the instance's cron rather
   than ash_oban's generated scheduler (`scheduler_cron false` on the trigger).
   ash_oban still provides the worker/trigger machinery; MDL bypasses only its
   insertion calls.
2. Patch ash_oban to thread an instance and vendor the patch (no hex/github
   access in this sandbox, so this is a local-fork commitment).
3. Scale the e2e back to one client instance (gives up the F3 fix).

Whichever is chosen: add a **Phase 2 spike item** ("enqueue + cron-sweep into a
_named_ Oban instance end-to-end") — this is precisely the class of third-party
assumption Phase 2 exists to de-risk, and it is currently asserted, not proven.
Phase 3's `oban_instance` deliverable should state the mechanism, not just the
option.

### R2 (moderate) — the two-instance repo story is supported, but the plan should name the hook

Good news first: the mechanism F3 asked for exists. ash_sqlite's `repo` option
is `{:or, [{:behaviour, Ecto.Repo}, {:fun, 2}]}`
(`ash_sqlite-0.2.17/lib/data_layer.ex:199-205`), resolution honors a per-query
context override (`context.data_layer.repo`, `data_layer.ex:2080-2090`), and
ecto_sqlite3 inherits Ecto's dynamic-repo machinery unchanged (no adapter-level
singleton). Two runtime instances over two SQLite files are achievable.

But the plan's two-instance paragraph says only "instance config carries the
SQLite file path", and the three available hooks have different ergonomics: the
`{:fun, 2}` repo option receives `(resource, type)` — **no
tenant/actor/context** — so it can only distinguish instances via process or
global state; the per-query context override is clean but must be injected on
every call the app makes (and by MDL's own internal reads/writes — flush,
refresh, hydrate — which originate inside the library, not the app);
`put_dynamic_repo` is per-process and must be set across every process tree an
instance owns (LiveViews, Oban workers, strategy processes). Pick the mechanism
and record it in Phase 7's two-instance paragraph — MDL's internal call sites
are the part that won't be obvious later, since library-issued Ash calls need to
carry whatever the choice is. (Also fold into the R1 decision: Oban workers
execute in the instance's own supervision tree, which is where dynamic-repo
selection has to be established.)

### R3 (minor) — F4 was applied to Phase 6 but not to the facts section

The facts section still opens the ash_remote_cache entry with "two components,
both pure consumers of MDL/ash_remote public APIs" (plan line ~129), while Phase
6 now correctly inventories **five** modules including the 149-line `CacheLayer`
— which is not a pure consumer in the same sense (it's the stopgap the C4
fold-back retires). One sentence fixes the self-contradiction the plan's own
metadata claims is resolved.

### R4 (minor) — the `Capability` precedent in Phase 4a is slightly overstated

"Extend the existing `AshMultiDatalayer.Capability` pattern — it already does
exactly this for expressions" — verified: `Capability` does per-**expression**
probing (`:expression_calculation` support + every `Ash.CustomExpression`
VM-evaluable, `capability.ex:33-39`), called from exactly two cache-side sites
with source fall-through (uncomputable-calc sort routing, ValueMerge calc
split). It does **not** today check a query's full serving shape
(filter/sort/aggregate structure). The per-query serving-degradation deliverable
is new machinery following the same pattern, not an extension of an existing
check — worth a word-level correction so Phase 4a's estimate isn't anchored on
"mostly exists".

### R5 (nit) — `{:atomic, _}` wording in the facts

ash*sqlite answers true to exactly three explicit clauses —
`{:atomic, :update | :upsert | :create}` (`data_layer.ex:452-454`); any other
`{:atomic, *}`hits the catch-all`false` (`:514`). Functionally irrelevant to the
argument (the bypass-guard must still refuse them), but the facts section states
a wildcard that isn't one.

### R6 (minor) — two transitional-state consistencies worth one sentence each

- **Phase 4's LocalOutbox `can?` is partially masked until 4a.** Phase 4
  delivers "joins answer whatever the local layer answers", but Phase 1's shell
  keeps unconditional `false` for joins/combinations/bulk-atomic until Phase 4a
  moves the hardcodes into strategies. Harmless (Phase 4's gate doesn't exercise
  joins), but the checklist reads as if the answers are live in Phase 4.
- **Phase 1 vs the revised behaviour ADR.** The ADR now states "the shell
  hardcodes no capability answers" (its can?-derivation section, revised
  2026-07-05), while Phase 1 — "the behaviour seam per the ADR" — deliberately
  keeps the shell's hardcoded `false`s until 4a. The deferral is the right call
  (pure-refactor gate); Phase 1 should just note the capability-placement
  exception the way it already notes the inbound- callback deferral.

### R7 (observation) — multitenancy on the flagship's sqlite resources

Phase 4a keeps `:multitenancy` as the all-layers intersection (load-bearing,
agreed), and ash_sqlite answers `false` (`data_layer.ex:491`). Consequence:
every sqlite-backed LocalOutbox resource is non-multitenant — fine for the
flagship (ownership is policy-scoped, not tenant-scoped), and the `OutboxEntry`
extension's verifier requires SQL-backed hosts anyway, but the LocalOutbox
verifier list ("order shapes, outbox contract, deps present, stale-check field
trackable, single-node") could add the explicit no-tenancy-on-sqlite rejection
so the failure is a verify-time message rather than a puzzled runtime `false`.

## Review-1 findings: incorporation check

| #                                         | Status in revision                                                                                                                                                                                                                                      |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| F1 co-commit predicate                    | **Fixed.** Phase 4 predicate is same-Ecto-repo + raw `Repo.transaction/1`, explicitly not `can?(:transact)`; Phase 2 item 8 reframed around the hardcoded `false`; facts record the capability surface. Caller-visible honesty note is a good addition. |
| F2 shell-change split                     | **Fixed.** Phase 4a exists; Phase 4 gained an inspection-checkable seam gate; `read_from:`/`write_through:` tests moved to 4a's gate; dependency line updated (7 needs 4a).                                                                             |
| F3 two-instance + oban_instance           | **Partially fixed.** Mechanism stated, `oban_instance` committed to Phase 3, OQ4 resolved — but the mechanism relies on ash_oban capabilities that don't exist (R1) and leaves the repo-selection hook unnamed (R2).                                    |
| F4 five-module inventory                  | **Fixed in Phase 6**; facts section left contradicting it (R3).                                                                                                                                                                                         |
| F5 scaffold decision + LiveView JS        | **Fixed.** Decision stated with rationale (generator-target layout, Oban Web router, install-path test); JS note carried with the todo_client precedent.                                                                                                |
| F6 13 callbacks                           | **Fixed.** Full ADR surface in Phase 1, optionals marked, deferral stated.                                                                                                                                                                              |
| F7 `seq` on SQLite                        | **Fixed.** New Phase 2 item 9 with both candidate designs; renumbering (payload → item 10) carried through OQ3.                                                                                                                                         |
| F8 fix-plan status / blocking_layer tense | **Fixed** in facts.                                                                                                                                                                                                                                     |
| F9 facts touch-ups                        | **Fixed.** Line count dropped, evict-on-update wording in Phases 4 and 6, keyset-no-flag in facts + item 7. The RFC's OQ3 label was also fixed RFC-side (verified: it now reads "Phase-2 spike … plan Phase 2 item 10").                                |
| F10 breadcrumb + path-dep note            | **Fixed.** Both in Phase 6.                                                                                                                                                                                                                             |
| F11 snooze pre-answered                   | **Fixed.** Item 5 is a confirmation test; facts record the verified path.                                                                                                                                                                               |

## New claims verified without issue

- All five shell-`can?` characterizations in Phase 4a are accurate: `:transact`
  write-intersection (`data_layer.ex:257,313-325`) vs `transaction/4` delegating
  to `hd(write_layer_modules)` alone (`:330-338`, same for
  rollback/in*transaction?);
  `{:lock,*}`falling to the read-intersection making the`run_query` lock branch (`:513-520`) unreachable; `:multitenancy` all-layers (`:297-299`); `:select` authority-only (`:306-311`).
- **N10** exists verbatim in
  `docs/reviews/20260704-implementation-review.md:382` and says what the plan
  says (dead lock-routing branch; answer `{:lock,_}` from the source alone).
- The aggregate-filter crash is implementation-review **M3** (`:232-253`,
  "Confidence: certain (reproduced)"), matching the plan's
  `KeyError :__ash_bindings__` characterization; M3 itself recommends the
  `can?(:aggregate_filter) → false` refusal Phase 4a adopts. Note it is a
  reproduced review finding, not a committed repro test — Phase 4a's "refuse
  loudly" gate test will be its first committed assertion.
- ash*sqlite capability facts: every listed clause matches
  (`:transact`/`{:lock,*}`/`:multitenancy`/`:distinct`/`:distinct*sort`/ `{:aggregate,*}`/`:aggregate_filter`false;`:update_query`/ `:destroy_query`/`:bulk_create`
  true) — modulo the R5 atomic-wildcard nit.
- Today's `:aggregate_filter`/`:aggregate_sort` answers are indeed the generic
  read-intersection (no explicit clause), i.e. advertised-then- crash, which is
  what makes 4a's explicit `false` a behavioural fix.
- The revised behaviour ADR carries the same per-feature-class derivation as
  Phase 4a (authority-only / serving-set / all-layers / write / bypass-guards),
  so plan and ADR agree on the end state (modulo the R6 transitional note).

## Suggested plan edits, in one list

1. **R1**: add the named-Oban-instance spike item to Phase 2; respec Phase 3's
   `oban_instance` deliverable with the chosen mechanism (recommend: MDL-owned
   insertion via the generated worker + `scheduler_cron false` + MDL sweep
   worker in the instance cron).
2. **R2**: name the repo-selection hook in Phase 7's two-instance paragraph,
   including how MDL-internal calls (flush/refresh/hydrate) carry it.
3. **R3**: fix the facts section's "two components" line.
4. **R4/R5**: calibrate the Capability-precedent sentence; correct the
   atomic-wildcard wording.
5. **R6**: one-sentence transitional notes in Phase 1 (capability-placement
   deferral vs revised ADR) and Phase 4 (LocalOutbox `can?` masked until 4a).
6. **R7** (optional): add the no-tenancy-on-sqlite rejection to the LocalOutbox
   verifier list.

---

**Last Updated**: 2026-07-05
