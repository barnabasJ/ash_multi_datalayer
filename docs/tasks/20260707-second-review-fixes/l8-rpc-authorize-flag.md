# L8 — RPC dispatch lacks explicit `authorize?: true`

- **Status**: DONE — `subject_opts/1` (the single shared helper `dispatch/4`,
  `fetch!/3`, and `validate_action/3` all route their
  `Ash.Query`/`Ash.Changeset` subject through) now includes `authorize?: true`
  unconditionally. Fixing this one function fixes every server-side Ash call in
  the RPC dispatch at once — read, create, update, destroy, and the
  update/destroy fetch-helper.

  New `AshRemote.Backend.WhenRequestedDomain`/`WhenRequestedThing` (test
  support, registered in `config/config.exs`'s test-only `ash_domains` list):
  `authorize :when_requested`, read allowed for any present actor,
  create/update/destroy allowed only for `role: :admin`.

  **Empirical finding that reshaped the test design** (via
  `Ash.Actions.Helpers.add_authorize?/3`): under `:when_requested`, Ash already
  implicitly sets `authorize?: true` whenever the caller's opts include an
  `:actor` key at all — `subject_opts/1` always includes `actor:` whenever
  non-nil. So an actor-present request was, in effect, already authorized even
  before this fix; the **only** scenario this fix changes on a `:when_requested`
  domain is the anonymous (no-actor) request — exactly the defect description's
  own framing. The 3 "no actor is denied" tests (read/create/update) are the
  ones confirmed via stash to fail on unfixed code. The pass-7-High
  "read-authorized but mutate-forbidden" tests (update/destroy/create) do NOT
  discriminate this specific fix on this domain config for the reason above, but
  are retained anyway as valuable end-to-end proof that the underlying policy
  logic itself is correct (an actor that can read is still denied at the
  terminal mutation call, not merely at the fetch).

  `/rpc/validate` explicitly excluded from enforcement, with a recorded reason
  (per the task's own allowance): `validate_action/3` never runs the actual
  action — `Ash.Changeset.for_create/4`/`Ash.Query.for_read/3` don't evaluate
  policies at construction time regardless of `authorize?:`; policies run during
  the action pipeline (`Ash.create!/1` etc.), which this endpoint never calls.
  Confirmed empirically: a create-forbidden actor still validates successfully.
  Judged acceptable because the blast radius is bounded — this endpoint never
  returns resource data or performs a write/read, only
  `{"success" => boolean, "errors" => [...]}}` reflecting input-shape validity.
  A real fix would mean routing through `Ash.can?/3` — a materially larger
  change (a second authorization code path) than this task's scope.

  `mix test` green in `../ash_remote` (224/226 — the 2 remaining failures are
  the same pre-existing, unrelated `ChangeNotifierTest` issue noted in
  M7/M8/M11).

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
