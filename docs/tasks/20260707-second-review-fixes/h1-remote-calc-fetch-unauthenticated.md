# H1 — Bundled remote-calculation fetch runs unauthenticated (#8)

- **Status**: OPEN
- **Severity**: High (auth bypass / wrong-actor values)
- **Repo**: ash_remote
- **Verification**: AGENT (traced by review agent, not independently
  re-confirmed)
- **Source**:
  [20260707 implementation review — H1](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Original finding**: #8
- **Plan ref**: Workstream R phase R3 item 1
- **Files**: `../ash_remote/lib/ash_remote/data_layer.ex:320,335`;
  `remote_calculation.ex:68-92`

## Defect

`fetch_remote_calculations/4` takes only `tenant` (no actor/context) and its
request passes no headers (`request(cfg, :run, body)` — headers default `[]`),
unlike the authenticated read path
`request(cfg, :run, body, request_headers(query.context))`.

## Failure scenario

`Ash.load!(records, :remote_calc, actor: user)` on cache-layer rows → the bundle
request carries no Bearer token → the backend denies the legitimate user, or
(worse) returns values computed without the actor's authorization context.

## Fix

Thread actor/context into bundled remote-calculation fetches and build request
headers with the same auth path used by ordinary reads
(`request_headers(context)`). Preserve tenant threading (plan R3 item 1).

## Done when

- [ ] Repro test: actor-authenticated remote-calculation load sends the auth
      header (assert at the transport/test-server boundary) — fails on unfixed
      code with no header
- [ ] Explicit context-header test: a caller-supplied
      `context: %{ash_remote: %{headers: ...}}` reaches the bundled
      remote-calculation request — not just the actor-derived authorization
      header (spec review: `request_headers(context)` also carries configured
      context headers; a fix could pass the actor-token test while still
      dropping these)
- [ ] Tenant still threads through the bundle request
- [ ] **Memoization is actor-scoped (pass-7 High)**: `fetched_values/4`
      (`remote_calculation.ex:74`) memoizes bundles in the process dictionary
      under `{__MODULE__, resource, phash2({pk_values, specs, context.tenant})}`
      — the key excludes actor/headers. Add a repro: two same-process loads with
      **different actors** but the same tenant/PK/specs must NOT reuse the first
      actor's values (fails on unfixed code by returning actor A's bundle to
      actor B). Fix by including auth-relevant context in the memo key or
      scoping/clearing the memo per load
- [ ] **Same-actor / different-headers memo repro (loop-1 review)**: also vary
      caller-supplied `context.ash_remote.headers` with the same actor/tenant/
      PK/specs — the memo key must not reuse across differing explicit request
      headers either (an actor-only key would still leak here)
- [ ] Full `mix test` green in `../ash_remote`
