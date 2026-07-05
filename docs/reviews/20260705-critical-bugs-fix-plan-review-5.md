# Plan Review (fifth pass) — the four-amendment critical-bugs-fix-plan.md

**Date:** 2026-07-05
**Scope:** the amended `docs/plans/critical-bugs-fix-plan.md` (the version
carrying both Review-disposition tables and the pass-4 amendments), reviewed
against all four prior passes and the current `lib/` + `deps/ash` source.
**Method:** every new/changed mechanism since pass 3 (lazy atomic seeding,
reconcile-in-`maybe_backfill` placement, evict-before-image-PK, kill-switch
interaction, rescue-safe epoch reads, `forget!` NotLoaded probe) was checked
against source — including the Ash filter evaluator, to verify the
NotLoaded-vs-nil claim directly. Interleavings for the epoch/reconcile paths
were re-derived.

**Verdict:** the plan is implementable. The lazy-seed-at-snapshot fix (pass-4
N1) is the right design and resolves the cold-start regression pass-4 caught;
the reconcile-placement decision (pass-3 W1 → pass-4) correctly keeps the PK
set out of `record`'s signature while making the opaque gate explicit; and the
`forget!` NotLoaded-probe rule is **verified correct against
`Ash.Filter.Runtime`** (details below — pass 4 raised it but did not cite the
evaluator code that proves it). One real spec gap remains: the remainder-path
reconcile needs the complement filter `¬C` that nothing currently threads into
`maybe_backfill`. The rest is precision.

---

## Verified sound (amendments since pass 3, checked against source)

- **Lazy atomic seeding — `:ets.update_counter(table, key, 0, {key,
  System.unique_integer([:positive])})`.** Sound and resolves pass-3 W2 /
  pass-4 N1 fully. `update_counter` is atomic insert-if-absent-then-read, so
  concurrent seeders/first-bumpers can't torn-seed; `System.unique_integer`
  is monotonic within a VM instance, so a TableOwner supervisor restart or
  `Coverage.reset/1` (which `delete_all_objects`s the epoch row) produces a
  value no in-flight snapshot can equal; and snapshot-time absence now *seeds*
  rather than aborts, so a read-only cold start records coverage (Phase 1's
  acceptance gate holds). A full-VM restart carries no in-flight snapshots
  (their processes died too), so cross-VM `unique_integer` recurrence is
  harmless. One property worth a code comment: `bump_epoch/2` must use the same
  default shape so a first-bumper on a never-read partition seeds consistently
  with a first-reader.
- **Reconcile placement in `maybe_backfill` behind a shared `Coverage` gate.**
  Resolves pass-3 W1. Keeping physical-row deletion (`Delegate` + `Backfill`)
  out of the ledger module is the right separation; exposing
  `recordable? ∧ ¬opaque?` as a public helper lets `maybe_backfill` gate
  reconcile + record together, so an opaque Q is never replayed against the
  cache for reconciliation. `record`'s internal gates remain as backstop.
- **`forget!` PK-only NotLoaded probe — VERIFIED against the evaluator.**
  `Ash.Filter.Runtime.resolve_ref/5` (`deps/ash/lib/ash/filter/runtime.ex:1042-
  1051`) returns `:unknown` for a `%Ash.NotLoaded{}` attribute when
  `unknown_on_unknown_refs?` is true (the probe is evaluated via
  `matches_or_unknown?` at `invalidation.ex:43`, which passes `true` and maps
  `:unknown → drop`). A plain `nil` value is **not** NotLoaded, so
  `Ash.Resource.selected?/2` treats it as loaded → `resolve_ref` returns
  `{:ok, nil}` → the predicate evaluates under Ash's nil semantics
  (`nil > 5` → falsy) → **definite non-match → the entry survives while the
  physical row is evicted → silent row loss**. The plan's "NotLoaded, never
  nil" rule is therefore necessary, not pedantic. Pass 4 raised the rule but
  did not cite the evaluator; this pass confirms the two divergent code paths
  (`resolve_ref` + `selected?`) that make nil- and NotLoaded probes behave
  differently. The unit test the plan names is the right pin.
- **Evict-on-update by the before-image's PK (pass-4 N4)** — correct; for a
  PK-changing update the before-PK is always the stale row, the after-PK heals
  via normal upsert/refetch.
- **Kill-switch interaction (pass-4 N6)** — sound: the evict is part of
  invalidation, which `WriteDispatch` already runs unconditionally while
  disabled (`write_dispatch.ex:19-21, 81-83`); updating the moduledoc is the
  right touch. Both "evict while disabled" and "skip while disabled" are safe;
  the plan picks the single-code-path option.
- **Epoch reads rescue-safe (pass-4 N7)** — correct and consistent with the
  review's N3 class; any `ArgumentError` from a dying table ⇒ "moved" ⇒ abort
  caching / drop the entry, never a crash on the read path.
- **Mid-reconcile bump (pass-4 N2)** — re-confirmed: reconcile may delete a
  concurrently-propagated fresh row, but check/verify skips the record insert,
  so the outcome is a later miss (degradation, never staleness). The
  "tolerated-degradation" wording is accurate.

---

## Findings

### W1. The remainder-path reconcile needs `¬C`, which nothing threads into `maybe_backfill`

`plan:388-418`, `data_layer.ex:786-806, 890-919`.

The plan specifies two reconcile shapes — full Q on the source-miss path, and
**Q ∧ ¬C only** on the remainder path (the covered half "must not be reconciled
against the source set"). Both shapes execute from `maybe_backfill`, which the
F4 amendment gives the signature `maybe_backfill(query, resource, read_layers,
source_rows)`. On the remainder path `source_rows` is the Q ∧ ¬C fetch, but the
reconcile still needs the **complement filter** to build the cache-side scan —
`maybe_backfill` has Q (from `query`) and the source-row PKs, but not ¬C. ¬C is
computed in `remainder_read`'s caller (`coverage_split`) and never passed in.

This is not a "the implementer will figure it out" gap the way a naming choice
is: scanning full Q and deleting ∉ source-set **deletes every covered row**
(their PKs are legitimately absent from the ¬C-only fetch), so the restriction
to ¬C is load-bearing, not cosmetic. And `coverage_split` cannot be silently
recomputed inside `maybe_backfill` as a fix-without-a-plan either — it *works*
(the epoch guard guarantees the entry set is stable across the guarded window,
so a recompute returns the same C), but the plan should say so deliberately,
because elsewhere it is meticulous about not recomputing coverage state mid-
read.

**Pick one and state it**, mirroring the plan's precision elsewhere: either
(a) thread the complement as an opt — `maybe_backfill(query, resource,
read_layers, source_rows, complement: ¬C_filter)` (nil on the source-miss
path, where full Q is scanned) — or (b) document that `maybe_backfill`
recomputes `coverage_split` for the reconcile region and state why that is safe
under the epoch guard. As written an implementer reaches `maybe_backfill` with
no way to obtain ¬C and no instruction to recompute.

### S1. The epoch snapshot is a write on every miss-path read

`plan:231-247`. `epoch/2` uses `:ets.update_counter(table, key, 0, default)` —
`update_counter` acquires the write lock even with increment 0 (it must, to
honour the insert-if-absent default). So every miss-path read does an ETS
**write** to seed-or-read the epoch, contending the per-tenant epoch key. The
hit path (`covers?` → `coverage_read`) does not touch the epoch, so this is
scoped to misses only, and the op is fast — likely fine in practice. But the
plan presents the design as cost-free; it is trading a write-on-every-snapshot
for the simplicity of no separate seeding step. Worth either one sentence
acknowledging the trade-off, or noting the read-mostly alternative
(`:ets.lookup` first; `:ets.insert_new` only on the rare absent case; re-
`lookup`) if profiling later shows epoch-key contention. Not blocking.

### S2. `bump_epoch/2`'s default should be stated to match `epoch/2`'s

`plan:247-248`. The plan specifies `epoch/2`'s `update_counter` default
explicitly but says only "bump_epoch — `:ets.update_counter/4` with the same
seeded default" for `bump_epoch/2`. A first-time writer on a never-read
partition must seed identically to a first-time reader, or the reader's
snapshot and the writer's first bump could land different base values (both
unique, both safe, but the wording should make the "same default shape"
contract explicit so an implementer doesn't diverge — e.g. a `bump_epoch` that
defaults to `0` would let a never-read-then-written partition seed at 0 and
match a pre-crash `0` snapshot from the old table). One clause: "`bump_epoch/2`
uses the identical default tuple as `epoch/2`."

---

## Review-trail accuracy (minor)

The disposition table (plan:599-610) and pass 4's adjudication attribute
"p3-F1" (remainder reconcile laundering inside `C`) and "p3-F3" (PK-only
`forget!` probe) to pass 3. Pass 3 actually labelled its findings **W1, W2,
S1, S2, S3** and placed the reconcile-restriction-to-Q∧¬C under **"Verified
sound"**, not as a finding — it did not flag laundering-inside-C, nor raise the
`forget!` PK probe. Both concerns are real and the amendments are correct
(pass 5 verified the `forget!` one against source); the misattribution is an
audit-trail issue, not a correctness one. If the trail is meant to be
machine-traceable (the disposition tables read that way), relabel as e.g.
"raised in pass 4, re-examining a pass-3 verified-sound item" rather than
"p3-F1". If it's prose, leave it.

---

## Summary

1 warning (W1 — thread `¬C` to `maybe_backfill` for the remainder reconcile, or
document a recompute), 2 suggestions (epoch-snapshot-is-a-write trade-off;
state `bump_epoch`'s default matches `epoch`'s), 1 review-trail note. No
criticals.

This is the smallest pass so far because the four amendments did the heavy
lifting: the lazy seeding closes the cold-start hole, the reconcile placement
+ shared gate closes the opaque-evaluation hole, and check-insert-verify
remains sound on re-derivation. W1 is the only item that should be resolved in
the plan text before Phase 0 starts — it's a "where does ¬C come from"
question the implementer will hit immediately at the reconcile call site, and
the answer changes `maybe_backfill`'s signature (which the plan otherwise
specifies precisely).

---

**Last Updated**: 2026-07-05
