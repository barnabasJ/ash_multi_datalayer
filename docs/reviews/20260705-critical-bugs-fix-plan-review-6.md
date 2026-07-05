# Plan Review (pass 6) — the twice-amended critical-bugs-fix-plan.md

**Date:** 2026-07-05 **Scope:** the second amendment of
`docs/plans/critical-bugs-fix-plan.md` (the version whose disposition table
covers passes 1–4: p3-W1/W2/S1–S3 and p4-N1/N2/N4–N7), reviewed against all four
prior passes and the source. **Method:** every new disposition row was checked
against the finding it disposes and the plan text implementing it; the
newly-specified mechanisms (seed-at-snapshot epoch,
reconcile-in-`maybe_backfill` behind the shared gate, before-image PK eviction,
kill-switch posture, `NotLoaded` probe rule) were re-derived the same way as
passes 2 and 4.

**Verdict:** the second amendment is faithful — all twelve pass-3/pass-4 rows
are correctly adopted, the reconcile placement resolves p3-W1 the right way
round (reconcile in `maybe_backfill`, PK set out of `record`'s signature, a
shared recordable∧non-opaque gate), decision 7's rescope says exactly what pass
4's adjudication argued, and Phase 6.5 makes the reconcile scope executable. One
soundness gap survives in the adopted epoch-seeding mechanism (F1 below — the
seed value space is not collision-free against bump arithmetic, so the
crash-window race the seeding exists to close can still slip through it), and
one cold-start side door remains open (F2). Both are one-line-class fixes inside
Phase 3. The rest is coherence-level.

---

## Verified: second-amendment adoptions re-derived

- **p3-W1 placement** — reconcile in `maybe_backfill` behind a shared public
  `Coverage` gate (recordable ∧ non-opaque), PK set kept out of `record`'s
  signature: sound, and the plan's reasoning for preferring this over
  reconcile-inside-`record` (physical row deletion doesn't belong in the ledger
  module) is a better argument than pass 3's lean the other way. The opaque
  query can no longer reach a cache-side `Delegate` replay it can't evaluate;
  `record`'s internal gates remain as backstop. Consistent on both backfilling
  paths (the remainder path arrives already opaque-gated by Phase 2).
- **p4-N1/p3-W2 seeding** — the atomic seed-at-snapshot
  (`update_counter(table, key, 0, {key, unique_integer})`) is adopted with the
  correct rule (snapshot-time absence seeds; check-time mismatch aborts) and
  `table_owner.ex` was rightly dropped from Phase 3's file list. One gap
  survives — F1 below.
- **p4-N4** — before-image PK for the update evict: adopted, correctly reasoned
  for PK-changing updates.
- **p4-N6** — kill-switch: "evict runs regardless because invalidation is never
  skippable" is the right resolution (confirmed: `WriteDispatch` invalidates
  outside the `KillSwitch.enabled?` guard), and the moduledoc update is named.
- **p4-N7** — rescue-safe epoch reads: adopted in the mechanism section.
- **p3-F3/p4 adjudication** — the `%Ash.NotLoaded{}`-never-`nil` probe rule for
  PK-only `forget!` is stated with the correct nil-semantics reasoning, and the
  pinning unit test is named.
- **p3-S1** — the last-writer-union imprecision note is accurate: each
  widening's claim is computed from fields its own backfill physically wrote, so
  a lost widening under-claims (transient miss), never over-claims. No CAS
  needed; correctly accepted.
- **Decision 7 rescope + Phase 6.5** — matches pass 4's adjudication precisely,
  including the two-case pin test (evict-failure residue converges via
  reconcile; forgotten-invalidation ghost persists until `forget!`).
- **p3-S2/S3, p4-N2/N5** — signature blast radius, strategy-specific cost notes,
  mid-reconcile tolerated-degradation wording, table label: all present where
  the table says.

---

## F1 (must fix, Phase 3 mechanism): the epoch value space is not collision-free — a fresh seed can equal a stale bumped value, reopening the crash-window race the seeding exists to close

The seeding fix compares a reader's snapshot against the current epoch value,
relying on `System.unique_integer([:positive])` "never repeating for the node's
lifetime". That guarantee holds between **raw outputs** of `unique_integer` —
but bumped epochs are not raw outputs, they are `seed + k` after `k` writes.
`unique_integer([:positive])` without `:monotonic` draws from dense
per-scheduler counters (small integers, scheduler-striped), so nothing prevents
a **fresh post-restart seed `S2`** from numerically equalling a **pre-restart
bumped value `S1 + k`**:

1. Reader snapshots `epoch0 = S1 + k` (seed `S1`, `k` bumps so far).
2. Writer bumps + drops + propagates; TableOwner crashes and restarts (VM stays
   up — `unique_integer` state persists, ETS state does not).
3. Next epoch access seeds `S2`. If `S2 == S1 + k` — structurally possible,
   since both live in the same dense small-integer space and `k` is attacker^W
   workload-controlled — the reader's check passes and it backfills + records
   from pre-write state on the fresh table.

This is precisely the interleaving pass-2 F6 / pass-4 N1 set out to close; the
current mechanism narrows it (from "always passes" to "passes on arithmetic
coincidence") rather than closing it. The window still requires a TableOwner
crash or `reset/1` in exactly that gap, so likelihood is low — but the
mechanism's entire reason for existing is that window, and the exact fix is
trivially cheap:

**Fix: make the epoch a pair — `{counter, incarnation}` — and compare both.**
Store the object as `{key, counter, incarnation}`:

```elixir
# seed-or-read (snapshot):
incarnation = System.unique_integer([:positive])
:ets.update_counter(table, key, {2, 0}, {key, 0, incarnation})  # returns counter
# plus an :ets.lookup to read the incarnation alongside — or lookup-first,
# insert_new on miss, re-lookup: any atomic shape that yields {counter, inc}

# bump:
:ets.update_counter(table, key, {2, 1}, {key, 0, incarnation_default})
```

Readers snapshot and compare the **pair**. Within one incarnation, bumps make
the counter strictly move (any write ⇒ mismatch — the C3 guarantee); across a
restart or `reset/1`, the incarnation is a fresh raw `unique_integer` output,
which genuinely never repeats within the VM lifetime, so no stale pair can ever
compare equal regardless of counter arithmetic. A node restart wipes the ETS
table _and_ the readers, so cross-VM reuse is moot. (A cheaper approximation —
seeding with `unique_integer * 10^9` so a collision needs 10⁹ bumps within one
incarnation — also works, but the pair is exact and no harder.)

## F2 (should fix, Phase 3 protocol): the epoch snapshot must `ensure_table` — two read paths reach `maybe_backfill` without ever creating the table

The seed-at-snapshot call sits on the coverage ETS table, but two recordable
read paths reach `source_read` → `maybe_backfill` **without ever passing through
`covers?`/`ensure_table`** (`data_layer.ex:502-538`): the uncomputable-calc-sort
branch (`:calc_sort_source_only` — a calc-sort query with no limit _is_
recordable; sort doesn't block recording) and the non-mergeable computed branch
(`:not_cacheable`). On the very first read of a resource arriving via one of
those branches, the table doesn't exist: the snapshot's `update_counter` raises,
the rescue (correctly, per p4-N7) treats it as "abort caching" — and since the
same path repeats on every subsequent identical read, **that query shape never
backfills or records** until some other query happens to create the table. That
is the same cold-start-never-caches class the second amendment just fixed for
the absent-epoch rule, surviving through a side door.

**Fix:** `Coverage.epoch/2` (the snapshot entry point) starts with
`ensure_table(resource)` — a cheap `:ets.whereis` when the table exists — and
aborts caching only when `ensure_table` itself returns `{:error, :unavailable}`
(supervisor missing: the existing degraded mode). One line, and it makes the
snapshot total across every path that can reach `maybe_backfill`.

## Coherence-level items

- **F3 — check-time absence is unobservable if checks seed.** The plan uses
  `Coverage.epoch/2` — "the seeder" — for snapshot _and_ check-time reads, but
  then says "check-time absence can only mean the table died mid-read". With a
  seeding read, check-time absence never surfaces: a restarted table yields a
  _fresh seed_ (present, mismatching), and a dying table takes the rescue path.
  Either make check-time reads a plain non-seeding `:ets.lookup` (absence then
  observable and meaning what the plan says), or drop the dead clause. With F1's
  pair-compare this is cosmetic — mismatch catches everything — but the sentence
  as written will confuse the implementer writing the check.
- **F4 — double normalisation in the shared gate.** The p3-W1 resolution has
  `maybe_backfill` consult the shared gate (which normalises Q) and then
  `Coverage.record` normalise again internally as backstop. Fine for
  correctness; for the hot path, let the gate return the normalised probe and
  pass it into `record` (it already gains an `epoch0` parameter — one more
  optional argument spares a second full normalise per backfill). Perf-polish,
  bounded by the 32-disjunct cap either way.
- **F5 — the disposition table cites pass-3 findings that no longer exist at the
  cited file.** `p3-F1` and `p3-F3` reference the _original_ review-3 content,
  but that file was rewritten in place (it now carries the first-amendment
  review: W1/W2/S1–S3); the adjudicated originals survive only inside pass 4's
  adjudication section. The table already says "via p4 adjudication" — make that
  the explicit pointer (link pass 4's section) so the audit trail doesn't
  dead-end for a reader diffing the table against review-3 as it stands today.

---

## Summary

1 must-fix (F1 — pair the epoch with an incarnation token; counter arithmetic
over dense `unique_integer` seeds can collide across restarts, leaving the
crash-window race narrowed but not closed), 1 should-fix (F2 — snapshot must
`ensure_table`, or the calc-sort/non-mergeable read paths never cache from a
cold start), 3 coherence items. Everything else in the second amendment checks
out: all twelve pass-3/pass-4 dispositions are faithful, the reconcile placement
is the right resolution of p3-W1, and no earlier finding is reopened. With F1
and F2 folded into Phase 3's mechanism text, this plan is ready for Phase 0.

---

**Last Updated:** 2026-07-05
