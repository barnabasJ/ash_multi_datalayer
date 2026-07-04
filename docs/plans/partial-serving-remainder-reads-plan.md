# Partial Serving via Remainder Reads — Implementation Plan

**Metadata:**

- Type: plan
- Status: implemented (2026-07-04) — see the
  [Fetch-Only-The-Missing-Subset ADR](../design/20260704-fetch-only-the-missing-subset-adr.md).
  Superseded detail: this plan's risk-ordering (OR-decomposition first, negation
  later) was **not** followed — the general nil-safe complement is sound and
  general from the start, so it shipped directly.
- Created: 2026-07-03
- Topic: partial-serving-remainder-reads
- Depends on: v1 (implemented), computed-value merge reads
  ([ADR](../design/20260703-computed-value-merge-reads-adr.md))

## Executive Summary

- **Feature**: When a query's result is only _partially_ covered by the ledger,
  serve the covered part from the cache and fetch **only the missing rows** from
  the source of truth, instead of falling through whole. Two mechanisms, shipped
  in order of risk:
  1. **OR-decomposition** — a union query whose covered disjuncts come from
     cache and whose uncovered disjuncts are fetched verbatim. No negation
     anywhere.
  2. **Nil-guarded remainder filters** — for one covered entry `C`, fetch
     `Q ∧ ¬C` where every negated interval carries an explicit `is_nil` escape
     hatch, restoring the law of excluded middle that Ash's nil semantics
     otherwise break.
- **Correctness stance unchanged**: everything conservative-on-unknown; every
  new proof obligation gets its own property suite cross-checked against
  `Ash.Filter.Runtime`; any doubt → full fall-through (today's behaviour is
  always the fallback).
- **Complexity**: Medium-high. The complement construction is new solver
  machinery with the same blast radius as `implies?/2`.

## Why nil makes this hard (recorded so the plan survives context loss)

A remainder read is sound only if `rows(Q) = rows(Q ∧ C) ∪ rows(Q ∧ ¬C)`. Ash's
match semantics evaluate a comparison over a nil operand to `nil` (non-match)
**and** its bare negation to `nil` (also non-match) — measured against
`Ash.Filter.Runtime` during v1: `age < 2` and `not (age < 2)` are _both_
non-matches for `age = nil`. A naive remainder `not (age > 18)` therefore
silently drops every nil-aged row from the union. Worse, the semantics are not
compositional (bare `not` propagates nil; `or` collapses it to false), so
classical rewrites are untrustworthy — this is why the v1 solver treats `not` as
opaque. The fix is to never emit `not` at all: complements are built **per
interval, in positive form, with explicit `is_nil` disjuncts** (`¬(age > 18)` ⇒
`age <= 18 OR is_nil(age)`), which SQL and the ash_remote wire encoder also
handle identically (`IS NULL` — no three-valued `NOT` anywhere). Attributes
declared `allow_nil?: false` skip the guard.

## Soundness rules (normative)

1. **The cache side must be filtered to `Q ∧ C`, never plain `Q`.** The cache
   layer's table holds rows from _all_ backfills; rows outside proven coverage
   may be deleted-at-source phantoms. Coverage guarantees only the `C` region.
   `Q ∧ C` is a conjunction — no negation needed, built with
   `Ash.Filter.add_to_filter!/2`.
2. **The two parts are disjoint by construction** (`C` excludes nils on its
   constrained attributes; `¬C` includes them), but merge by primary key anyway,
   preferring the fetched row on any collision — defence in depth.
3. **Eligibility**: no sort, no limit, no offset, no distinct, no lock, no
   computed loads (v1 of this feature; see Non-Goals). Sorted/limited results
   cannot be assembled from two sources without top-k machinery.
4. **Fields**: the covered entry's `loaded_fields` must ⊇ the query's needed
   fields, exactly like a full hit.
5. **Complement blowup cap**: complementing a DNF yields a CNF that must be
   re-expanded; reuse the 32-disjunct cap. Over the cap → full fall-through.
6. **Snapshot note**: the merged result mixes cache-at-T₁ with source-at-T₂.
   Same exposure class as any cache hit after an out-of-band write; must be
   documented in the guide, and the divergence sampler applies to partial reads
   (shadow = full `Q` against the source).
7. **After a partial read the result set is complete for `Q`**: backfill the
   fetched remainder rows and **record `Q`** — the next such query is a full
   hit. Coverage still grows toward the workload.

## Non-Goals

- Combining partial serving with computed-value loads (merge reads require full
  row coverage; composing the two is a follow-up).
- Multi-entry unions of coverage (`C₁ ∨ C₂` as the covered region) — v1 uses the
  single best entry; the entry-selection heuristic is an open question below.
- Top-k assembly for sorted/limited queries.
- Any general `not` support in the solver. Complements are a closed,
  per-interval-kind table; anything outside it is ineligible.

## Phases

### Phase A — Shared plumbing + OR-decomposition (no negation)

**Objective**: split-read infrastructure and the safe special case: for
`Q = D₁ ∨ … ∨ Dₙ` (the normalised DNF), serve covered disjuncts from cache and
fetch only uncovered disjuncts.

**Deliverables**:

- `Coverage.partial_plan/3` →
  `{:full_hit, entry} | {:partial, covered_filter, remainder_filter} | :miss`.
  For Phase A: partition `normalise(Q).disjuncts` by
  `implies?(disjunct, entry.normalised)` across entries; remainder = the
  uncovered disjuncts rendered back to a filter.
- **Interval → Ash filter renderer** (`Coverage.Render`): normalised DNF →
  filter statement using only positive forms (`eq`/`not_eq`/`in`/range
  comparisons/`is_nil`) — needed by both phases, keeps `not` off the wire.
- `PartialRead` in the read path: cache side runs `Q ∧ covered` on the first
  layer, remainder goes to the last layer; PK-merge (fetched wins); backfill
  remainder rows; record `Q`; emit `[:ash_multi_datalayer, :read, :partial]`
  with `%{cached_count, fetched_count, duration_us, ledger_size}`.
- Eligibility gate per soundness rules 3–5; anything ineligible falls through
  exactly as today.

**Gate**: integration — warm `name == "a"`, query `name == "a" or name == "b"`:
cached part served (zero source rows for the `"a"` branch, assert via
CountingLayer + a source query observing only the `"b"` filter), union correct,
follow-up identical query is a full hit. Property: for generated `Q` in OR form
and generated coverage, merged result set == full-fall-through result set (same
seeded rows).

### Phase B — Interval complements (nil-guarded)

**Objective**: `Coverage.Complement.complement/1` — the complement of a
`Normalised` as another `Normalised`, never using `not`.

Per-kind table (each ∨ `is_nil(attr)` unless `allow_nil?: false`):

| kind          | complement                                            |
| ------------- | ----------------------------------------------------- |
| `:eq v`       | `:not_eq v`                                           |
| `:not_eq v`   | `:eq v`                                               |
| `:in [vs]`    | `:not_in [vs]` (**new Interval kind**, conj of ≠)     |
| `:range l..u` | `:range ..l` (flipped bound) ∨ `:range u..` (flipped) |
| `:is_nil`     | `:not_nil`                                            |
| `:not_nil`    | `:is_nil`                                             |
| `:opaque`     | ineligible (whole complement fails)                   |

`¬(D₁ ∨ … ∨ Dₙ) = ¬D₁ ∧ … ∧ ¬Dₙ`; `¬D` for a conjunction over attributes is the
disjunction of per-attribute complements. The ∧ across disjunct complements
reuses the existing merge/unsatisfiable-drop machinery, capped at 32.

**Deliverables**: `:not_in` support in `Interval` (`contains_value?`, `subset?`,
merge rules — extend `implies?` coverage), `Complement.complement/1`, renderer
support for `:not_in` (conjunction of `!=`).

**Gate**: the union-completeness property suite —
`match(Q, row) ⇒ match(Q ∧ C, row) ∨ match(render(Q ∧ ¬C), row)` and the
disjointness dual, 10k cases over nil-heavy generated rows, ground truth
`Ash.Filter.Runtime`. This suite _is_ the safety argument; the per-kind table is
just the construction.

### Phase C — Remainder reads

**Objective**: wire Phase B into `partial_plan/3`: when no full hit and
OR-decomposition doesn't apply, pick a covered entry `C`, remainder =
`Q ∧ complement(C)` (merged, capped, rendered). Entry selection v1: most
recently used entry whose complement survives the cap and whose `loaded_fields`
suffice.

**Gate**: integration — warm `age > 18`, query all: cached adults + fetched
`age <= 18 OR is_nil(age)` remainder; **a nil-aged row appears in the result**
(the row the naive scheme silently drops — this is the flagship regression
test); deleted-at-source phantom in the covered region does NOT resurface (rule
1); follow-up query is a full hit. Example proof: a Browse-panel scenario in
`example/` (warm one status tab, query All, assert the fetch only carried the
other status).

### Phase D — Docs

ADR (promote this plan's soundness rules), technical doc read-path + edge-case
updates, guide (“partial hits” + snapshot note), telemetry reference for
`[:read, :partial]`, runbook note.

## Open Questions

| Question                                                         | Notes                                                                                                               |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Entry-selection heuristic when several entries partially overlap | v1: MRU-first that passes cap+fields. Measuring overlap size = estimating cardinality — punt.                       |
| Multi-entry covered regions (`C₁ ∨ C₂`)                          | Complement of a union is cheap (∧ of complements) but the cache-side filter grows; defer until a workload wants it. |
| Should `[:read, :partial]` also emit `:backfill`?                | Leaning yes (it does backfill + record) — decide in Phase A.                                                        |
| Interaction with divergence sampler rates                        | Partial reads shadow the full `Q`; same knob, note in docs.                                                         |

## Risks

| Risk                                                                                      | Mitigation                                                                                                                                                                                                            |
| ----------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Complement construction unsound in an untested corner (the `implies?` blast radius)       | Union-completeness property suite is the phase gate; renderer emits only positive forms; ineligible-on-any-doubt.                                                                                                     |
| Remainder judged by two evaluators (Ash runtime on cache side, SQL/remote on source side) | No `not` on the wire; only `=`, `!=`, `in`, comparisons, `is_nil` — forms whose null semantics agree across SQL, Ash runtime, and the ash_remote encoder. Renderer output round-trips through `normalise/2` in tests. |
| Cache-side phantom rows                                                                   | Rule 1 (`Q ∧ C` on the cache side) + dedicated integration test.                                                                                                                                                      |
| `:not_in` widens the solver surface                                                       | Its `subset?`/merge rules get added to the existing solver property suites, not just the new one.                                                                                                                     |
| Wide complements slow or useless                                                          | 32-cap → fall-through; telemetry on how often the cap trips (decide whether to emit in Phase A).                                                                                                                      |

## Test Strategy

- Property (new): union completeness + disjointness (Phase B gate); renderer
  round-trip (`normalise(render(n)) ≡ n` on supported forms).
- Property (extended): existing implication/normalisation suites gain `:not_in`
  generators.
- Integration: partial-hit scenarios above, phantom-row regression, nil-row
  flagship regression, follow-up-full-hit, cap-exceeded fall-through,
  eligibility fall-throughs (sort/limit/computed).
- Example: one Browse-panel partial-hit scenario in
  `example/todo_client/test/todo_client/multi_datalayer_test.exs` with RPC
  counting (fetch carries only the remainder).

---

**Last Updated**: 2026-07-03
