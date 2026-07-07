# Review: the 2026-07-06 review-findings fix plan (pass 3)

**Date**: 2026-07-06 **Input**: the [amended plan](../plans/20260706-review-findings-fix-plan.md)
(after it absorbed [pass 1](./20260706-review-findings-fix-plan-review.md) and
[pass 2](./20260706-fix-plan-review.md)), re-checked against source. **Verdict**:
the plan is now implementation-ready. Both prior criticals are genuinely fixed —
not just claimed — and I verified each rewrite against the code it touches. One
new inaccuracy in the M-6 migration guidance (the outbox constraint is
transformer-injected, so "re-run the generator" is wrong) and a few cost/edge
notes are all that remain. No criticals, no warnings that block a gate.

As in pass 2, every claim below was verified by reading source, not the plan's
restatement. Severities: **warning** = inaccurate guidance that will mislead
operators; **suggestion** = precision/cost.

---

## Prior criticals — resolved (verified)

### M-1 (A1-1) — the ID-capture design is correct and necessary

The rewrite (capture chain entry IDs → apply changeset → destroy captured IDs
only → kick) preserves invariant 1's error half: if the apply raises at step (b),
nothing has been destroyed yet, so the parked chain is intact. I confirmed the
necessity claim, because pass-2 S2 (which called capture "unnecessary") is now
correctly marked superseded: `record_chain/1` (`api.ex:380`) and `drop_chain/1`
(`api.ex:391`) query by `(resource, record_pk, target, state != :synced)`. After
the apply, the fresh entries share that exact key with the old chain, so a
key-scoped drop after the apply is the original bug — only entry IDs distinguish
old from new. Capture is load-bearing under this design, exactly as the amended
Facts section states. Sound.

### M-3 (A3) — on_write-style invalidation closes the race; the test now hits the right window

The rewrite reuses `Invalidation.on_write`'s machinery as a destroy-style
invalidation per ghost (drop covering entries via `should_drop?`, evict, bump
once per batch). This is the fix pass-2 C1 asked for: `covers?/3`
(`coverage.ex:239`) never consults the epoch, so the only thing that removes
reader R2's already-committed entry P is the entry drop — and `on_write/4`
(`invalidation.ex:84`) is bump + evict + **drop**, confirmed. With P dropped,
the next read is a miss and refetches `r` from source. The accepted consequence
(the initiating read's own `Coverage.record/5` sees `:epoch_moved` and skips) is
correct — `record/5` (`coverage.ex:357`) re-checks the epoch at `verify_or_drop`
(`coverage.ex:425`), and a self-evicted batch has moved it. The A3 gate's
"next identical read misses, refetches, records cleanly, hits thereafter"
assertion is the right recovery check. A0-3 now correctly parks R1 inside
`reconcile_layer`'s cache-layer scan (after the `epoch_moved?` guard at
`proven_coverage.ex:698`), so it exercises the committed-entry path rather than
aborting at the guard. Both halves of the pass-2 C1/C2 pair are closed.

### M-6 (A2) — both downstream edits now named

A2-1 correctly adds the `:auth` value to the `error_class` `one_of`
(`inject_outbox.ex:84`) and a third `apply_result/6` clause (`flush.ex:95`) for
the immediate-park behavior. I verified the `error_class` constraint is exactly
`one_of: [:transient_exhausted, :rejected, :conflict]` and that `apply_result/6`
branches only on `:rejected`/`:transient` today — both edits are required for the
plan to function. M-2's materialization approach is also sound:
`Ash.Changeset.apply_attributes/1` (ash `changeset.ex:7564`) calls `set_defaults`
(uuid PKs, timestamps) then folds `changeset.attributes` over `changeset.data`,
returning `{:ok, record}` — so the common create is fully populated pre-commit,
and the nil-PK guard correctly rejects genuinely DB-generated keys.

---

## Warning

### W1 — "re-run the generator" is wrong; the `error_class` constraint is transformer-injected

A2-1(a) says existing generated outbox resources "need the constraint
regenerated — note it in the CHANGELOG as a required `mix
ash_multi_datalayer.gen.outbox` re-run or manual constraint edit." That
overstates the migration, and the suggested remediation is a no-op for this
change.

The generated outbox file (`lib/mix/tasks/ash_multi_datalayer.gen.outbox.ex:144`)
writes only `extensions: [AshMultiDatalayer.Sync.OutboxEntry]` and an
`outbox_entry do … end` block — it does **not** emit the `error_class` attribute
or its `one_of` constraint. Those are added at compile time by the transformer
`sync/transformers/inject_outbox.ex:82` (`attr(:attribute, name: :error_class,
type: :atom, constraints: [one_of: [...]], …)`). So adding `:auth` to the
transformer's `one_of` propagates to every outbox resource on the next
**recompile** — no generator re-run (the generator doesn't own this attribute),
no manual file edit, and no DB migration (`:atom` is stored as a string, so a new
allowed value doesn't change the column). The CHANGELOG note should read "library
upgrade + recompile," not "re-run `gen.outbox`." As written, an operator would
either skip a step that's unnecessary or, worse, hunt for a literal constraint in
their generated file that isn't there.

---

## Suggestions

### S1 — A3: per-ghost `should_drop?` scans the whole ledger

"Entry drops are per-ghost, only the bump is batched." `should_drop?`
(`invalidation.ex:40`) filters the full `Coverage.entries(tenant)` list, so a
reconcile evicting N ghosts does N full-ledger scans — O(N × ledger) for the
batch. Correctness is unaffected (the union of drops is the same), but for a
large reconcile batch this is quadratic-ish. Consider collecting all ghost rows
first, then scanning the ledger once and dropping any entry whose filter matches
**any** ghost. The batched epoch bump the plan already specifies is the model for
this.

### S2 — A1-2: note what `apply_attributes/1` does not capture

`apply_attributes/1` folds only `changeset.attributes` over `changeset.data`
(`changeset.ex:7570`); it does not apply `changeset.atomics` (atomic-expression
updates) or action lifecycle side-effects. The shell already refuses atomics
(`proven_coverage.ex:98`, `can?(_resource, {:atomic, _})` → false), so this is
unlikely to surface in a write_through path — but the nil-PK guard would be more
complete as "reject a write_through changeset carrying atomics or a still-nil PK
after `apply_attributes`." Also handle the `{:error, changeset}` return
(`apply_attributes/1` fails closed on an invalid changeset, `changeset.ex:7579`)
rather than assuming `{:ok, record}`.

### S3 — A1-2: call signature wording

The plan phrases the materialization as `apply_attributes/2` "over
`changeset.data`." The actual call is `Ash.Changeset.apply_attributes(changeset)`
(the data is the internal reduction seed, `changeset.ex:7570`) returning
`{:ok, record} | {:error, changeset}` — there is no two-argument form that takes
the data. Minor, but an implementer reading the plan literally will look for the
wrong function head.

---

## What still looks sound

- **Repro-first discipline and gates** remain exemplary; A0-1 gained assertion
  (d) (resolution-fails case) and A0-2 gained the field-for-field materialization
  test — both directly close loops the prior passes opened.
- **The Review disposition is accurate**, including the call to supersede pass-2
  S2: "capture is unnecessary" reviewed the dead drop-before-apply design; under
  drop-after-by-ID it is load-bearing. That kind of self-correction is the right
  instinct.
- **The amended Facts all check out** against source: `on_write` does
  bump+evict+drop; `covers?` has no epoch check; `maybe_backfill` guards before
  `reconcile`; `drop_chain` keys on `(resource, record_pk, target)`; the
  field-policy target accessor exists (`Ash.Policy.FieldPolicy` has a `:fields`
  field, `field_policy.ex:8`, so `field_policies |> Enum.flat_map(& &1.fields)`
  yields target fields, not condition refs — B1-3's target-vs-condition split is
  correct).
- **M-7** is now explicitly doc-only in the header and A4-5 — no longer silently
  dropped.
- **R-2 per-site maps** (B1-2), **R-3 dual-path strip** (B1-3), **ClientId
  base_url keying kept** (B3-2) — all match source and the prior-pass reasoning.

---

## Summary

**0 critical, 1 warning, 3 suggestions.** The two prior criticals are resolved
and source-verified; the plan can proceed to implementation. Fix the one
migration-note inaccuracy (W1: the `error_class` constraint is transformer-side,
so it's a recompile, not a generator re-run) in the CHANGELOG guidance before A2
lands, take or leave the cost/edge suggestions at your discretion, and the plan
is ready as written.
