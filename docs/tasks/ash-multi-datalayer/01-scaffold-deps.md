# Task 01: Scaffold deps in `mix.exs`

**Phase**: 1 — Deps + stub **Depends on**: None **Blocks**: 02, 03 **Size**: S

## Objective

Add `ash`, `ash_postgres`, `spark`, `ecto_sql`, `postgrex`, and `stream_data` to
`mix.exs` and verify the project compiles. No Oban.

## Out of Scope

- Any library code (stays a scaffold until Task 02–03).
- Runtime configuration — that's Task 02.

## Context

The repo is currently a bare `mix new`. Before writing library code, we need the
right deps pinned so `iex -S mix` and tests can actually load Ash types.

## Detailed Steps

### 1. Edit `mix.exs` deps

Add the following to the `deps/0` function:

```elixir
defp deps do
  [
    {:ash, "~> 3.0"},
    {:ash_postgres, "~> 2.0"},
    {:spark, "~> 2.0"},
    {:ecto_sql, "~> 3.10"},
    {:postgrex, ">= 0.0.0"},
    {:stream_data, "~> 1.0", only: [:test]},
    {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
    {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
  ]
end
```

### 2. Set Elixir version floor

Ensure `elixir: "~> 1.18"` in the project. Confirm it matches CI.

### 3. Run `mix deps.get` and `mix compile --warnings-as-errors`

Confirm a clean compile.

## Files to Create/Modify

- `mix.exs` — deps.

## Patterns to Follow

- `ash_postgres/mix.exs` (upstream) — same pattern.

## Acceptance Criteria

- [ ] `mix deps.get` succeeds.
- [ ] `mix compile --warnings-as-errors` succeeds.
- [ ] `iex -S mix` boots and `Ash.Resource` is callable.

## Definition of Done

- [ ] Code compiles with no warnings
- [ ] Deps resolve to the expected versions
- [ ] No unrelated files touched

## Verification

```bash
cd ../../..
mix deps.get
mix compile --warnings-as-errors
iex -S mix -e "IO.inspect Ash.Resource"
```

## Notes

- Do NOT add Oban. See
  [ADR 20260417-no-write-behind-in-v1](../../design/20260417-no-write-behind-in-v1-adr.md).
- If `ash_postgres` 2.x pulls a stale `spark` version, align manually.
