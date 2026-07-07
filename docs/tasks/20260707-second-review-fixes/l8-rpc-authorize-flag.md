# L8 — RPC dispatch lacks explicit `authorize?: true`

- **Status**: OPEN
- **Severity**: Low (config-dependent authorization bypass)
- **Repo**: ash_remote
- **Verification**: AGENT
- **Source**:
  [20260707 implementation review — L8](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Files**: `../ash_remote/lib/ash_remote/server.ex:349-411` (dispatch), and
  the **fetch helper `fetch!/3` at
  `../ash_remote/lib/ash_remote/server.ex:434-436`**
  (`Ash.get!(resource, key, subject_opts(opts))` used by get?/update/destroy) —
  pass-6 review; it is outside the dispatch range but is one of the calls that
  needs `authorize?: true`

## Defect

The RPC server dispatch does not pass explicit `authorize?: true` to Ash calls.
A domain configured with `authorize :when_requested` runs anonymous RPC
**unauthorized** — policies are silently skipped.

## Fix

Pass `authorize?: true` on **every** server-side Ash call in the RPC dispatch —
read, create, update, destroy, and any helper fetches used by update/destroy —
so authorization runs regardless of the domain's `authorize` setting. A partial
fix (read-only) leaves policy bypasses on the mutation paths.

## Done when

- [ ] Test coverage across **read, create, update, destroy, and fetch-helper**
      paths: each denies an unauthorized RPC on a `:when_requested` domain with
      a policy — fails on unfixed code by succeeding (spec review: a single-case
      test can hide bypasses on the other verbs)
- [ ] **Mutation auth must not pass via fetch denial only (pass-7 High)**: the
      update and destroy tests use an actor **authorized to fetch/read the row
      but forbidden to mutate it** — proving `Ash.update!/1`/`Ash.destroy!/1`
      run with `authorize?: true` on the terminal mutation call, not just that
      `fetch!/3` (`server.ex:434-436`) denied the read. Create gets an analogous
      create-policy denial independent of read/fetch
- [ ] **`/rpc/validate` covered (loop-1 review)**: `validate_action/3`
      (`server.ex:309-330`, routed at `router.ex:53`) builds
      `Ash.Query`/`Ash.Changeset` subjects via `subject_opts` with no
      `authorize?: true` — the same bypass as the dispatch. Either test it under
      a `:when_requested` policy or explicitly exclude it with a recorded reason
- [ ] Any deliberately excluded path is documented with why it cannot bypass
      policies
- [ ] Authorized requests still pass on every verb
- [ ] Full `mix test` green in `../ash_remote`
