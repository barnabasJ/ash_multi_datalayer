# B2 — Aggregate-filter code injection at codegen time

- **Status**: OPEN
- **Severity**: Blocker (security — arbitrary code execution)
- **Repo**: ash_remote
- **Verification**: VERIFIED
- **Source**:
  [20260707 implementation review — B2](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Original finding**: #7 (CRITICAL in plan)
- **Plan ref**: Workstream R phase R2 item 3
- **Files**: `../ash_remote/lib/ash_remote/gen/generator.ex:374-375` (also
  loader pass-through)

## Defect

`aggregate_block/2` splices `field.aggregate_filter` raw into generated source:

```elixir
filter_line =
  if field.aggregate_filter, do: "\n      filter expr(#{field.aggregate_filter})", else: ""
```

with no `AshRemote.Expression.safe?` gate. `reproducible_aggregate?/1`
(line 361) only checks that a relationship is present. The calc path (~line 338)
_does_ gate on `safe?`; the aggregate path does not. The loader passes
`field["aggregate_filter"]` through unvalidated.

## Failure scenario

A manifest with `aggregate_filter: "eval_something() or x"` on a
relationship-bearing aggregate produces `filter expr(<injection>)`, executing
arbitrary code at `mix ash_remote.gen`. The manifest is server-controlled, so a
compromised/malicious server executes code on every developer machine that
regenerates the client.

## Fix

Gate generated aggregate filters with `AshRemote.Expression.safe?` exactly as
the calc path does; unsafe or unreproducible filters fall back to `remote(...)`
proxies (plan R2 item 3).

**Loader/generator boundary (pass-5 review)**: pick and state the boundary
explicitly. The intended design (matching the calc path) is: the **loader
accepts** the `aggregate_filter` string as data (it does not execute or reject
on safety), and the **generator** is the single safety gate — it emits
`filter expr(...)` only when `safe?` passes, else a `remote(...)` proxy. So the
loader-level test asserts pass-through _without_ evaluation/rejection, and the
generator-level test asserts the `safe?` gate. Do not split the safety check
across both layers.

## Done when

- [ ] Repro test (generator): malicious `aggregate_filter` manifest falls back
      to a proxy — fails on unfixed code by emitting the injection
- [ ] Positive test (generator): a benign, `safe?` aggregate filter still
      generates `filter expr(...)`
- [ ] Loader-level test: `aggregate_filter` is passed through as data
      (shape/type only), NOT evaluated or safety-rejected at load time — the
      safety decision lives in the generator
- [ ] Full `mix test` green in `../ash_remote`
