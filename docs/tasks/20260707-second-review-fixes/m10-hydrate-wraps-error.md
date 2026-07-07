# M10 — `hydrate/2` wraps a possibly-`{:error, _}` refresh in `{:ok, ...}`

- **Status**: OPEN
- **Severity**: Medium (malformed return; callers treat failure as success)
- **Repo**: MDL (ash_multi_datalayer)
- **Verification**: AGENT
- **Source**:
  [20260707 implementation review — M10](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Original finding**: #18 family (structured errors on remote read failures)
- **Plan ref**: Workstream A phase A5 item 10
- **Files**: `lib/ash_multi_datalayer/orchestrator/local_outbox/api.ex:392-399`

## Defect

`{:ok, refresh(host_resource, :all, tenant)}` — since `refresh` can now return
`{:error, reason}`, `hydrate` returns the malformed `{:ok, {:error, reason}}`
(spec: `{:ok, map} | {:error, :outbox_not_empty}`).

## Fix

Propagate the refresh result: match `{:error, _} = err -> err`, wrap only
success. Update the spec to include the refresh error shapes.

## Done when

- [ ] Test: hydrate with a failing target read returns `{:error, reason}` —
      fails on unfixed code with `{:ok, {:error, ...}}`
- [ ] Spec matches the actual return shapes
- [ ] `INTEGRATION=1 mix test` green in MDL
