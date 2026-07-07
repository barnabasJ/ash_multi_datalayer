# B1 — RPC exfiltrates private calcs/aggregates; field-policy-denied field 500s

- **Status**: DONE — `fields.ex:132-134` switched to `Info.public_aggregate`/
  `Info.public_calculation`; repro + #27/#1-private-attribute retained
  regressions added (`test/backend/rpc_field_policy_test.exs`,
  `test/ash_remote/server/fields_test.exs`); full `mix test` green (185).
  Committed `ash_remote@b0d9af0`.
- **Severity**: Blocker (security)
- **Repo**: ash_remote
- **Verification**: VERIFIED (reviewer confirmed end-to-end in source)
- **Source**:
  [20260707 implementation review — B1](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Original findings**: **#1 has two sub-surfaces** (pass-6 review) — the
  **private calc/aggregate half is OPEN** (fail-first repro: `fields.ex:133-134`
  still use non-public `Info.aggregate`/`Info.calculation`) and the **private
  _attribute_ half is fixed-in-tree** (first-run fix; retained regression,
  expected to PASS). #27 is also fixed-in-tree (see below).
- **Plan ref**: Workstream R phase R1 items 1–2
- **Files**: `../ash_remote/lib/ash_remote/server/fields.ex:133-134`

## Defect

`attribute?`/`relationship?` (lines 132/135) correctly use
`Info.public_attribute`/`Info.public_relationship`, but `aggregate?`/
`calculation?` use the non-public `Info.aggregate`/`Info.calculation`, which
match `public? false` entities. `public_name/2` (line 141) therefore accepts a
private calc/aggregate name; it is loaded and serialized back to the client.

```elixir
defp aggregate?(resource, name), do: not is_nil(Info.aggregate(resource, name))
defp calculation?(resource, name), do: not is_nil(Info.calculation(resource, name))
```

## Failure scenario

`POST /rpc/run {"resource":"App.User","action":"read","fields":["internal_risk_score"]}`
where `internal_risk_score` is a `public? false` calculation → the server
returns its value. Reachable on read/create/update responses and nested
relationship selections. On a no-authorizer resource it is fully unauthenticated
PII exfiltration.

## Second surface — #27 (part of this task's scope)

Original #27 is the other half of R1 items 1–2 and is NOT covered elsewhere: a
field-policy-denied selected field returns `%Ash.ForbiddenField{}` (no
`Jason.Encoder`); `serialize` passes it through, `run_action` reports success,
then `Jason.encode!` at `router.ex:96` raises **outside** the rescue → raw 500.
Fix per plan R1 item 2: map the un-encodable field sentinels to nil (or omit)
per the wire contract in `value/1`/`loaded/1` — never pass them to Jason.

> **Sentinel correction (spec review, HIGH — verified 2026-07-07)**: the plan
> text names `%Ash.NotSelected{}`, but **that module does not exist** in the
> pinned Ash (`deps/ash/lib/` has only `Ash.NotLoaded` and `Ash.ForbiddenField`;
> `grep -r NotSelected deps/ash` is empty). An unselected field is represented
> as `%Ash.NotLoaded{type: :attribute}` — see `not_loaded.ex:6` moduledoc: "Used
> when a field hasn't been loaded **or selected**." So the two sentinels to
> handle are `%Ash.ForbiddenField{}` and `%Ash.NotLoaded{}`. Do NOT write a
> `%Ash.NotSelected{}` test case — it would not compile.
>
> ⚠ **Already fixed in the uncommitted working tree**: `fields.ex:97-102` maps
> both `%Ash.ForbiddenField{}` and `%Ash.NotLoaded{}` to nil in `value/1` and
> `loaded/1`, and `serialize` routes through them. So the #27 repro should PASS
> on current code — keep it as the retained regression test; do NOT expect the
> Jason crash. If it unexpectedly crashes, the fix regressed — reopen.

## Fix

Switch to `Info.public_aggregate`/`Info.public_calculation`. Public
calcs/aggregates (the only ones a client should legitimately name) keep working.
Apply the public-only rule to **both** field resolution (`to_select_and_load`)
and serialization (plan R1 item 1). The `ForbiddenField`/`NotLoaded`
serialization (#27) is already handled in-tree — retain it (see above).

## Done when

- [ ] Repro test (server RPC): requesting a `public? false` calculation and a
      `public? false` aggregate by name returns an error / omits the field —
      fails on unfixed code by returning the value
- [ ] Regression test (#27): a field-policy-denied selected field
      (`%Ash.ForbiddenField{}`) AND an unselected field
      (`%Ash.NotLoaded{type: :attribute}`) each serialize to a safe value, not a
      raw 500 — passes on current code (see the correction above); retained. No
      `%Ash.NotSelected{}` case (that module does not exist)
- [ ] #1 **private-attribute half** (fixed-in-tree, expected to PASS): retained
      regression here or in R0 before this task closes. Distinct from the #1
      **private calc/aggregate half** above, which is the OPEN fail-first repro
- [ ] Positive test: a public calculation and public aggregate still resolve
- [ ] Covers nested relationship field selection AND create/update responses
      (any path that can return requested fields), not just top-level reads
- [ ] Full `mix test` green in `../ash_remote`
