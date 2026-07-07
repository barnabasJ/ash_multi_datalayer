# L7 — Data-layer LOWs: header dedupe, write retries, composite PK, filter/sort encoding

- **Status**: OPEN
- **Severity**: Low (batch)
- **Repo**: ash_remote
- **Verification**: AGENT
- **Source**:
  [20260707 implementation review — L7](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Plan ref**: Workstream R phase R3 items 6, 7, 8, 9, 11
- **Files**: `../ash_remote/lib/ash_remote/data_layer.ex:322`,
  `remote_calculation.ex:46,71`, `encode/filter.ex:96`, transport/request
  building

## Defects (unaddressed R3 items)

1. Possible duplicate `authorization` header:
   `transport.headers ++ extra_headers` — static config token and actor token
   both emitted. Dedupe by case-insensitive name with an explicit precedence
   rule.
2. `retry` config applied to non-idempotent write POSTs — scope retries to
   idempotent read/run requests.
3. Composite-PK `[pk] =` crashes in `data_layer.ex:322` and
   `remote_calculation.ex:46,71`.
4. `ref_name/1` drops `relationship_path` (`encode/filter.ex:96`) — filter refs
   become silently unscoped; keep the path or reject such references.
5. Sort on a parameterized calculation drops its arguments.

## Done when

- [ ] Header dedupe test with both static and actor tokens that **asserts the
      chosen precedence rule** (which token wins) and case-insensitive duplicate
      names — not merely that a dedupe happened (spec review: a dedupe-happened
      test passes with an arbitrary/unstable winner)
- [ ] Write POSTs are not retried; reads still are
- [ ] Composite-PK resources exercise the remote-calculation paths without
      `MatchError`
- [ ] Relationship-path filter refs encode correctly or error; parameterized
      calc sort preserves args
- [ ] Full `mix test` green in `../ash_remote`
