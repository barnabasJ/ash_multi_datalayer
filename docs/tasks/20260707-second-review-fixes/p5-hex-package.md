# P5 — `mix hex.build` fails; package metadata/docs config missing

- **Status**: OPEN — re-verified 2026-07-07: `mix.exs:54` still has
  `{:crux, "0.1.3", override: true}` and no `package`/`description` config
- **Severity**: Release blocker (only if/when publishing to Hex)
- **Repo**: MDL (ash_multi_datalayer)
- **Source**:
  [20260704 implementation review — R1](../../reviews/20260704-implementation-review.md)
  (added per
  [task-coverage review F2](../../reviews/20260707-second-review-fixes-task-coverage-review.md))
- **Files**: `mix.exs`; repo root

## Defect

As confirmed by running `mix hex.build` in the original review:

1. `override: true` on `{:crux, "0.1.3"}` makes the package unbuildable; the
   exact pin also over-constrains consumers (ash pulls crux transitively at
   `>= 0.1.2 and < 1.0.0-0`) — relax to `~> 0.1` or drop.
2. Missing metadata: `description`, `package` (licenses, links), `source_url`,
   `docs` config.
3. No `LICENSE` file in the repo root.
4. No `{:ex_doc, ...}` dep / `docs:` config → hexdocs publish fails; README
   links into `docs/guides/…` won't resolve without `extras`.
5. Hex's default file set ships `priv/test_repo/migrations/*` — needs an
   explicit `files:` list.

## Done when

- [ ] `mix hex.build` succeeds
- [ ] `mix docs` succeeds and README doc links resolve via `extras`
- [ ] LICENSE present; `files:` excludes test fixtures
- [ ] `INTEGRATION=1 mix test` green in MDL (per the index gate, even though no
      runtime surface changes)
