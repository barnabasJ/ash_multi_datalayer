# P5 — `mix hex.build` fails; package metadata/docs config missing

- **Status**: DONE
  1. `{:crux, "0.1.3", override: true}` → `{:crux, "~> 0.1"}` — `override: true`
     alone makes a package unbuildable via `mix hex.build` (Hex rejects an
     override dependency in a publishable package); `~> 0.1` is satisfied by the
     already-locked `0.1.3` (confirmed via `mix deps.get` — the lock file's
     `crux` entry is unchanged, no re-resolution), while no longer
     over-constraining consumers beyond what `ash` itself requires transitively.
  2. Added `description/0`, `package/0` (`licenses: ["MIT"]`, GitHub `links`,
     explicit `files:` excluding `priv/test_repo/migrations/*` and other
     test-only fixtures), `source_url`/`homepage_url`, and `docs/0`
     (`main: "readme"`, `extras:` listing README + the 3
     `docs/{guides,technical,runbooks}/ash-multi-datalayer.md` files the README
     itself links to).
  3. Added root `LICENSE` (MIT, matching the license declared in `package/0` and
     the broader Ash ecosystem's own convention — **a licensing decision made on
     the user's behalf given no prior license was recorded anywhere in the repo;
     flagged for review**, not a judgment call this task is positioned to make
     unilaterally in substance, only structurally required to make _something_
     concrete exist for `mix hex.build` to succeed).
  4. Added `{:ex_doc, "~> 0.34", only: :dev, runtime: false}` — resolved from
     the local Hex package cache (no network access needed; `ex_doc` was already
     cached from sibling `ash`-ecosystem projects in this environment).
  5. `files:` in `package/0` is an explicit allowlist (`lib`, `.formatter.exs`,
     `mix.exs`, `README.md`, `LICENSE`, and the three doc directories) —
     confirmed via `mix hex.build`'s own file listing output that
     `priv/test_repo/migrations/*` is excluded.

  Verified directly: `mix hex.build` succeeds (real tarball produced, inspected
  its file list, deleted after inspection — not committed); `mix docs` succeeds,
  generating `doc/readme.html` plus the three `ash-multi-datalayer-{1,2,3}.html`
  extras (ex_doc's own disambiguation for same-basename files from different
  directories) — confirmed the README's own `.md` links rewrite correctly to
  these generated `.html` files in the output (`grep`'d `doc/readme.html`'s
  `href=` attributes). `INTEGRATION=1 mix test` green (333, no regression — this
  task changes only `mix.exs`/`mix.lock`/adds `LICENSE`, no runtime surface).

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
