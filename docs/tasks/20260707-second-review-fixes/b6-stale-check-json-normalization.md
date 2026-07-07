# B6 — `remote_matches_payload?` dead for timestamped resources (#5 inert)

- **Status**: DONE — `remote_matches_payload?/3` now applies the same
  `json_scalar/1` normalization as the field-level fallback to both sides before
  comparing. Covers `drain_chain_inline` too — it calls the same `Flush.push/2`.
  Repro (StampWidget, `:utc_datetime_usec` stale field): target already equals
  the payload (simulating a worker dying after the push landed but before the
  entry synced) → retry must sync clean, not park a false conflict; fails on
  unfixed code (confirmed). `INTEGRATION=1 mix test` green (283 at the time, 289
  after Phase 3).
- **Severity**: Blocker (false conflicts block the PK chain)
- **Repo**: MDL (ash_multi_datalayer)
- **Verification**: VERIFIED
- **Source**:
  [20260707 implementation review — B6](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Original finding**: #5 (already-applied retry parks a false conflict)
- **Plan ref**: Workstream A phase A5 item 1
- **Files**:
  `lib/ash_multi_datalayer/orchestrator/local_outbox/flush.ex:231-235` (cf.
  correct normalization at 210-217)

## Defect

The already-applied fast path compares `Snapshot.dump(host, remote)`
(dump-to-embedded values: `%DateTime{}`/`%Decimal{}` structs) against
`entry.payload` (stored in a `:map` attribute, read back through SQLite's JSON
round-trip → ISO strings / plain numbers) with **no `json_scalar`
normalization** — although the field-level compare just below (lines 210-217)
applies exactly that normalization for exactly this reason.

## Failure scenario

With `conflict_detection: {:stale_check, :updated_at}`: a flush pushes the
update to the target, the worker dies before committing `:synced`, Oban retries;
the remote now equals the payload but `%DateTime{}` ≠ `"2026-…"` → fast path
fails → base-image compare parks the fully-succeeded write as a false
`:conflict`, blocking the per-PK chain. The guard only works for
string/integer-only resources.

## Fix

Apply the same `json_scalar` normalization used at lines 210-217 to the
`remote_matches_payload?` compare (both sides normalized to JSON-scalar space
before comparison). Cover the inline-drain path too (plan A5 item 1 says "Apply
the same guard to `drain_chain_inline`").

## Done when

- [ ] Repro test (plan A0 repro 7): resource with `:utc_datetime`/`:decimal`
      fields, remote already equals payload, retry → marks `:synced`, no park —
      fails on unfixed code by parking `:conflict`
- [ ] Same scenario through `drain_chain_inline`
- [ ] `INTEGRATION=1 mix test` (incl. `test/integration/local_outbox*`) green
