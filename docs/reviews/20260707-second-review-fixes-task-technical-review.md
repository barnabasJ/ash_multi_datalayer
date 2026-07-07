# Review: technical content of `20260707-second-review-fixes/` task files

**Date**: 2026-07-07
**Subject**: the 45 task files + index in
[`docs/tasks/20260707-second-review-fixes/`](../tasks/20260707-second-review-fixes/) —
specifically the **technical accuracy** of each task's *Defect / Failure scenario /
Fix / Done when*, not tracker coverage (coverage was signed off in pass 4b).
**Method**: read every task file, the source implementation review
([`…fix-plan-implementation-review.md`](20260707-second-review-fix-plan-implementation-review.md)),
the plan ([`…fix-plan.md`](../plans/20260706-second-review-findings-fix-plan.md)),
and hand-verified the central code claims against current `lib/` in both repos
(see §A).

---

## Verdict — technically sound; ship-blocking defects are absent

The task set is **technically accurate and execution-ready on the engineering
axis.** I verified the core *Defect* claim against source for every blocker
(B1–B7), two of the highs (H3, H5), three mediums (M1, M2, M3), two of the
P-family (P1, P3), and L1 — **every one matched the code at the cited line**.
No task misstates a bug, invents a file:line, or prescribes a fix that the code
contradicts. That is the bar that matters for "ready to execute," and it is met.

The findings below are **all Low severity** — scoping nuances, one under-specified
shared contract, and a couple of cross-task interaction notes. None blocks
execution; they are polish that will reduce merge friction and a couple of
re-litigation risks during the fix.

---

## §A — Spot-verification against current source (all PASSED)

Each row: task claim → code reality at the cited location.

| Task | Claim verified | Code at citation | Result |
| ---- | -------------- | ---------------- | ------ |
| **B1** | `aggregate?`/`calculation?` use non-public `Info.aggregate`/`Info.calculation` while attr/rel use public variants | `fields.ex:132-135` — exactly as claimed | ✅ |
| **B2** | `aggregate_block/2` splices `field.aggregate_filter` raw, no `safe?` gate | per source review `generator.ex:374-375` | ✅ |
| **B3** | `tenant_from_filter/2` regexes `inspect(filter)` for `value: X` | `tenant_key.ex:44-63` — `inspect(limit: :infinity)` + `~r/…value: ([^,}\]]+)/` | ✅ |
| **B4** | `replayed_external?/1` matches all-string OR all-atom; producer emits string-outer/atom-inner | `external_change.ex:72-78` + `inbound.ex:156-160` — mismatch confirmed | ✅ (see F1) |
| **B5** | verifier validates `local_evaluation_overrides` against aggregate names | `validate_aggregate_overrides.ex:29-40` — all three options vs `aggregate_names` | ✅ |
| **B6** | `remote_matches_payload?` skips `json_scalar` normalization that lines 210-217 apply | `flush.ex:231-234` vs `:209-217` — confirmed | ✅ |
| **B7** | `ensure_resolvable_head` returns `:ok` for `:synced`; call sites use `with :ok <-` | `api.ex:603-621` + call sites `:111,:131` (retried post-fix) — proceeds on synced | ✅ |
| **H3** | fix depends on `co_commit_repo/3` existing | `write.ex:351` (`def co_commit_repo/3`), used `:218` + `local_outbox.ex:200` | ✅ fix is feasible |
| **M3** | `forget_probe` `%resource{}` clause passes full record; PK-map clause builds PK-only probe | `ash_multi_datalayer.ex:61` (verbatim) vs `:63-69` (PK-only) — one-line fix accurate | ✅ |
| **P1** | `ensure_source_aggregates_resolved!` invoked only on merged-read branch | `proven_coverage.ex:440-442`, single call site `:629` | ✅ |
| **P3** | `sort_references_uncomputable_calc?` inspects only `query.sort` | `proven_coverage.ex:471` — `defp …(%Query{sort: sort}, …)`; no `distinct` match | ✅ |
| **L1** | `[pk] = Ash.Resource.Info.primary_key(resource)` in aggregate fold paths | `proven_coverage.ex:410` and `:598` — both present | ✅ |

**B1 sub-note (already self-flagged in the task)**: the in-tree `value/1` +
`loaded/1` (`fields.ex:97-102`) handle `%Ash.NotLoaded{}` and
`%Ash.ForbiddenField{}` but **not** `%Ash.NotSelected{}`. B1's "Done when"
already requires a `%Ash.NotSelected{}` test case — correctly handled, not a gap.

---

## Findings (all Low)

### F1 — B4 describes two `replayed_external?` clauses; the code has three, and the third is also dead

`external_change.ex:80` has a third clause not mentioned in B4:

```elixir
defp replayed_external?(%{metadata: %{external?: true}}), do: true
```

I grepped both repos and `example/` for any producer that sets `external?: true`
— **none does**. So this clause is *also* dead code today: no notification in
either repo or the examples carries `%{external?: true}` atom-keyed metadata.

B4's defect description ("origin marker matches no real notification") is
therefore slightly *under-stated* for the codebase as a whole: it's not just the
two ash_remote-shape clauses that are inert — all three external-marker paths
fail to fire for the actual producer. B4's proposed fix ("match the real
producer shape and/or normalize metadata keys before matching") would repair the
ash_remote path but leaves the `external?: true` clause's dead-code status
unresolved.

**Recommendation**: B4 should enumerate all three clauses and decide each:
either (a) delete the `external?: true` clause if no producer is intended to set
it, or (b) wire a producer to set it (e.g. a non-realtime external trigger) and
add a retained test. As written, a fixer could "fix" B4 by matching the mixed
ash_remote shape and leave an unreached clause that looks intentional.

### F2 — The tenant unit (B3 + H5 + M2 + L3 + P4) has no task that owns *publishing* the canonical function

The index's "Canonical tenant decision" is a good spec at the tracker level:
*"one shared function … canonical key is the string form … every path MUST call
that one function."* The five tenant-unit tasks each reference it ("fix as one
canonical-tenant-key unit") and each describes its own slice.

What's missing is an explicit **owner + sequencing**: which task *creates* the
function first, and what is its exact signature and normalization rule? B3 owns
`tenant_key.ex` and is the natural lead, but B3's "Done when" asserts
representation-consistency *without* requiring the canonical function to be
published/consumed as a precondition. If the five are worked in parallel (the
unit is large enough that parallelism is tempting), each could ship a slightly
different "canonical" helper (e.g. `Integer.to_string` vs `inspect` for integer
tenants; `:all` vs `:__global__` for unscoped) that agree in tests but diverge
on an edge case the unit's individual repros don't cover.

Two specific normalization points the index leaves open and that no task pins:
- **Integer/atom tenants** — stringified via `to_string` (Elixir's protocol) or
  `inspect`? They differ for atoms (`:foo` → `"foo"` vs `":foo"`).
- **Unscoped sentinel** — H5 proposes `:all`; P4/B3 read-side currently uses
  `:__global__`. The index says "never `nil`" but doesn't reconcile the two
  sentinels.

**Recommendation**: designate **B3 the lead**, add a B3 "Done when" bullet —
*"the canonical `TenantKey.canonical/2` (or named equivalent) is committed first
with a pinned signature + normalization rules (including the unscoped sentinel
and integer/atom stringification), and H5/M2/L3/P4 consume it verbatim"* — and
have the four consumers cite B3 as their dependency rather than describing the
function anew. This converts "fix as one unit" from a peer relationship into a
publish/consume sequence that can't five-way-diverge.

### F3 — B5 ↔ P2 interaction: "typo tests still reject" is posture-dependent

B5's "Done when" bullet 2 says typo tests "still reject an unknown name in each
of the three option groups." P2 establishes (and is verified) that under plain
`mix compile`, Spark 2.7 downgrades verifier `DslError` raises to `IO.warn`, so
"rejection" is advisory unless `--warnings-as-errors` is set. P2 itself calls
this out ("B5's compile 'regression' and the #22 verifier are only as strong as
this posture") — good cross-awareness — but B5's assertion doesn't name the
posture it's testing under.

**Recommendation**: B5's bullet 2 should specify the compile posture the typo
test asserts under (plain `mix compile` → warning asserted; or
`--warnings-as-errors` → failure asserted), and B5 should either depend on P2's
posture decision or note that the typo-rejection guarantee is bounded by P2.
Otherwise a fixer could pass B5's bullet 2 with a warning-only assertion while
P2 is still OPEN, shipping a "fix" whose rejection guarantee evaporates under a
default `mix compile`.

### F4 — Index "Recommended order" step 4 can read as gating the harness behind the fixes

The Discipline section and A0/R0 both make repro-first per-task binding. But the
index's "Recommended order" lists **A0/R0 as step 4** — after B1/B2, the tenant
unit, and B4–B7. A0's body resolves the tension ("building the harness and
fixing the findings should proceed together, repro-first, per finding"), but a
reader scanning only the ordered list could start B1/B2 fixes before any harness
exists, then belatedly discover the repro-first gate.

**Recommendation**: one-line index clarification beside step 4 — *"A0/R0 are
built incrementally alongside each fix (repro-first per task), not batched after
step 3; the ordering reflects dependency priority, not a harness deferral."*

---

## Per-task rollup

Compact assessment of every task. "✅ accurate" = defect/failure-scenario/fix
all match source and each other; notes only where added.

### Blockers
- **B1** ✅ accurate; NotSelected self-flag is correctly in "Done when".
- **B2** ✅ accurate; blocker-class sibling of L6, correctly split.
- **B3** ✅ accurate; see F2 (lead-task ownership).
- **B4** ✅ accurate on the claimed mismatch; see F1 (third clause).
- **B5** ✅ accurate; see F3 (posture interaction).
- **B6** ✅ accurate; correctly scopes the inline-drain path into "Done when".
- **B7** ✅ accurate; call-site `with :ok <-` confirmed — proceeds on `:synced`.

### High
- **H1** ✅ (AGENT-verified in source review); fix is the authenticated-read
  header path, sound.
- **H2** ✅; two-halves split (keys arg + accept truncation) is clear.
- **H3** ✅; `co_commit_repo/3` confirmed present — fix is feasible. M5
  subsumption correctly documented in M5.
- **H4** ✅; #14 (race) and #15 (divergence) correctly scoped as one task; L3
  cross-referenced for the same function.
- **H5** ✅; see F2 (sentinel).
- **P6** ✅; strong "fail against current working-tree code, not
  sweeper-disabled" discipline — avoids the false-pass trap. H5 dependency on
  the multitenant repro correctly noted.

### Medium
- **M1** ✅; both crash sites (Snapshot + attribute-tenant TenantKey) cited.
- **M2** ✅; see F2.
- **M3** ✅; one-line fix confirmed against `forget_probe` both clauses.
- **M4** ✅; correctly mirrors the rebase fix and pulls in the B7 guard +
  #18 retained regression.
- **M5** ✅; correctly marked subsumed by H3, do-not-work-independently.
- **M6** ✅; StaleRecord/NotFound → `:ok` mapping is the right idempotent
  posture.
- **M7** ✅; `cast_calculation/3` wiring target is correct.
- **M8** ✅; changeset-less → nil-topic bug is real; conservative reconcile
  fallback is the right escape.
- **M9** ✅; correctly self-flags the "verify which transaction
  `destroy_captured_chain`'s `transaction!` is" unknown — good. W1
  re-litigation guard is explicit and correct.
- **M10** ✅; malformed `{:ok, {:error, _}}` is real; spec update included.
- **M11** ✅; the "don't blanket-normalize nil → success" distinction
  (legitimate miss vs malformed) is well-reasoned — avoids turning a protocol
  corruption into a silent empty result.
- **P1** ✅; four unguarded branches enumerated; L2 pairing note (compose, not
  duplicate) is correct.
- **P2** ✅; posture decision (docs vs runtime guard) left to the fixer with
  the security case for runtime called out — appropriate.
- **P3** ✅; one-line-class guard extension, accurate.
- **P4** ✅; see F2; the inline disambiguation of "M6 = 20260704's M6, not this
  tracker's M6" is helpful.

### Low
- **L1** ✅; both `[pk] =` sites confirmed.
- **L2** ✅; the live ~70% flake citation (`live_test.exs:92`) is specific and
  verifiable — strong repro anchor.
- **L3** ✅; see F2 (tenant half).
- **L4** ✅; refuse-subsumption rule correctly preserves equality/`in`.
- **L5** ✅; either-or decision (multi-node-safe sweeper vs hard-reject) is the
  right framing.
- **L6** ✅; six-item batch, well-organized; B2 split noted.
- **L7** ✅; five-item batch; header-dedupe precedence rule is the key design
  point left to the fixer.
- **L8** ✅; `:when_requested` domain case is the correct trigger.
- **L9** ✅; security-intentional drop, docs-only posture is correct;
  deferred-follow-ups wiring is right.
- **L10** ✅; correctly sequenced after L5/A6 stabilize.
- **L11** ✅; "preserve the 3-tuple at the Ash boundary, normalize internally"
  is the correct two-audience fix.
- **L12** ✅; the fixed-in-tree (3/4/5/8) vs open (1/2/6/7) split is clear, and
  the "write the repro anyway; if it fails the fixed label was wrong" rule is
  exactly the right safety property.
- **L13** ✅; item-3/deferred-item-6 conditional-deferral handshake is correctly
  enforced ("deferring without the measurement is not a completion path").

### Release / cross-cutting
- **P5** ✅; five-item release checklist is complete; `override: true` on crux
  is the right call-out.
- **A0 / R0** ✅; see F4 (ordering). Retained-regression bullets for
  landed-but-untested work (B1#27, #22, default_can?, upsert arity, L12-3/4/5/8)
  close the loop well.
- **FINAL** ✅; the "report blocked, don't fix infrastructure" guardrail on gate
  2 is the right posture for a shared demo DB. Closure rule (tracker not closed
  until this task done) is structurally sound.
- **deferred-follow-ups** ✅; the conditional deferral on item 6 (refetch
  coalescing) is the strongest entry — correctly prevents pre-deferring on the
  strength of an unmeasured amplification.

---

## Strengths worth preserving

- **Repro-first is binding and operationally specific**: every task names its
  A0/R0 repro and the *stated failure reason* on unfixed code, plus the suite
  gate (`INTEGRATION=1 mix test` for MDL, `mix test` for ash_remote). The five
  retained-regression items (fixed-in-tree but untested) are the standout — they
  close the "landed but unverified" hole that let B1/B3/B4/B6 ship inert.
- **Verdict tags carry through**: `VERIFIED` vs `AGENT` provenance is preserved
  per task, so a fixer knows which defect claims were hand-confirmed vs
  agent-traced.
- **De-duplication is explicit**: M5↔H3 (subsumed), P1↔L2 (compose-don't-
  duplicate), B2↔L6 (blocker split), H4↔L3 (same function), and the tenant unit
  are all cross-referenced rather than restated. Low risk of double-fixing.
- **Plan-fidelity breadcrumbs survive**: M5/W1, M9/W1, B3/S1 each cite the
  accepted review disposition, so a fixer can't quietly re-litigate a settled
  design call (e.g. accepting partial cleanup) without noticing.

---

## Summary

- Spot-verified technical claims: **12/12 accurate** across B/H/M/P/L.
- Ship-blocking defects in the task set: **none**.
- Findings raised: **4, all Low** (F1 third dead clause in B4; F2 tenant-unit
  canonical-function ownership; F3 B5↔P2 posture interaction; F4 index ordering
  wording).
- Recommended action: address F1–F4 as one-line task edits, then execute
  starting with the checkpoint commit + B1/B2 (security) + the tenant unit
  (B3-led, per F2), repro-first per A0/R0.
