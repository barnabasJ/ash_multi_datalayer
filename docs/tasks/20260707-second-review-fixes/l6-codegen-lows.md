# L6 — Codegen LOWs: identifier validation, path traversal, FK fidelity, calc args

- **Status**: DONE — all 6 items addressed:
  1. **Identifier injection (the real, provable vulnerability)**: new
     `AshRemote.Gen.Identifier` (`lib/ash_remote/gen/identifier.ex`) validates
     every manifest-sourced bare identifier before it's spliced into generated
     source — attribute/relationship/calculation/aggregate/action/primary-key
     names, enum values, and module aliases (dotted, every segment a valid
     Elixir alias component). Invalid input raises the new
     `AshRemote.Gen.InvalidManifestError` rather than silently generating broken
     or malicious source. Wired into every raw-interpolation site in
     `generator.ex` (`gen_type`, `attribute_line`, `relationship_line`,
     `relationship_attribute_opts`, `calculation_block`, `aggregate_block`,
     `action_block`, `client_module` — the single choke point for module names
     since `res.module`/`type.module`/`rel.destination` all funnel through it).
     `accept_line` was audited and found already safe (renders via `inspect/1`,
     which self-escapes regardless of content). 21 tests (`gen_test.exs`'s
     "identifier safety (L6)" describe block + `gen/identifier_test.exs`'s unit
     coverage), confirmed via stash: on unfixed code every malicious-identifier
     test failed with "Expected exception ... but nothing was raised" — the
     identifier was silently spliced into generated source.
  2. **Path traversal**: investigated thoroughly and documented honestly
     (`test/mix/ash_remote_gen_output_path_test.exs`'s moduledoc) — on close
     reading of `Macro.underscore/1`'s actual algorithm, it structurally can
     never reproduce a literal `".."` from any input (every run of N consecutive
     dots alternates converted-to-`/`/survives-literally; proven by construction
     and confirmed empirically for several constructions), and Elixir's
     `Path.join/2` does not override on an absolute-looking second argument the
     way Ruby/Python do. So the literal line the task names was not
     independently exploitable for a real directory escape — item 1's
     module-name validation (which _is_ exploitable, via
     `defmodule #{module} do`) is what actually closes the gap here, since it
     refuses a bad module name before `Macro.underscore/1` or the path join ever
     run. A belt-and-suspenders `assert_contained!/3` containment check was
     added anyway (`Mix.Tasks.AshRemote.Gen.output_path/2` now calls it),
     satisfying the task's explicit "no path escaped the configured output root"
     assertion requirement, and is genuinely tested against a synthetic escaping
     path (bypassing `Macro.underscore/1` as input, the way a future refactor
     that dropped the identifier validator could reach it) — that part
     fails-first correctly. 6 tests, no disk I/O at all (pure path arithmetic).
  3. Calculation argument `allow_nil?` now reads `arg.allow_nil?` from the
     manifest (`arg.allow_nil? != false`, so unknown/missing data keeps the
     prior permissive default) instead of a hardcoded `true`. Live bug, not
     synthetic: the demo backend's `title_with_prefix` calc already declares its
     `:prefix` argument `allow_nil?(false)`, so this needed no manifest
     tampering to reproduce. 2 tests, confirmed via stash (unfixed code rendered
     `allow_nil?: true` for `:prefix`).
  4. `belongs_to` FK type/nullability: two compounding bugs, both fixed
     together. (a) `belongs_to_fks/1`'s FK-exclusion list mixed strings
     (`rel.source_attribute`, always present in a real manifest — see
     `AshRemote.Server.inject_relationship_attributes/2`) with atoms (the nil
     fallback), so the atom-only membership check at the `attributes do` call
     site never matched and the exclusion was silently inert — the FK ended up
     declared twice (once as an explicit `attribute`, once implicitly via
     `belongs_to`), and Ash's `BelongsToAttribute` transformer defers to
     whichever attribute already exists, which is _why_ the type/nullability
     wasn't actually being lost yet on the demo data. (b) Once (a) is fixed and
     the FK is correctly excluded from `attributes do`, Ash's `belongs_to` would
     fall back to its own `attribute_type: :uuid, allow_nil?: true` default —
     silently wrong for a non-uuid or non-nullable FK, the defect as the task
     describes it. Fixed by looking up the FK's real field data
     (`res.fields[fk_name]`) and passing `attribute_type:`/`allow_nil?:`
     explicitly on the `belongs_to` line. 3 tests: the demo's `user_id` FK is
     excluded from `attributes do` and carried on `belongs_to :user` instead; a
     synthetic non-uuid/non-nullable FK's real type/nullability survives; a
     manifest that doesn't publish the FK as its own field falls back to Ash's
     default without crashing. Confirmed via stash: both non-fallback tests
     failed on unfixed code (FK still appeared as a bare `:uuid` `attribute`,
     `belongs_to` carried no `attribute_type`). Full E2E test suite
     (`e2e_test.exs`, which actually compiles generated resources and exercises
     create/read through `user_id`/`parent_id`) stayed green throughout.
  5. `@known_atoms` gained the 9 aggregate-kind atoms
     (`:count`/`:sum`/`:avg`/`:min`/`:max`/`:first`/`:list`/`:exists`/`:custom`).
     2 tests: a direct `known_atoms/0` membership check, plus a genuinely
     discriminating fresh-OS-process repro (`System.cmd("elixir", ...)` against
     only the compiled `_build` artifacts, never loading `AshRemote.Gen`) —
     confirmed empirically that `:avg`/`:custom` specifically are _not_
     pre-existing atoms in a bare Elixir VM (the other 7 happen to be
     Erlang/Elixir builtins), so this is a real, not merely structural,
     discriminator. Confirmed via stash: the fresh-VM subprocess raised the
     exact `ArgumentError` the R-8 boot-order hazard predicts
     (`"avg", which is not a known Ash vocabulary atom"`).
  6. `reproducible_aggregate?/2` (now takes `relationships` too) additionally
     requires the aggregate's relationship to be one the generator will
     _actually emit_ — present in `res.relationships` with
     `type in [:belongs_to, :has_many, :has_one]`. Closes both causes uniformly:
     many-to-many (unsupported by `relationship_line/4` at all — silently
     dropped by its catch-all clause) and a relationship absent from the
     manifest entirely (e.g. private — `Ash.Info.Manifest` only publishes public
     relationships). Either way, without this check the aggregate would render
     `count :x, :bad_ref do ... end` against a relationship that doesn't exist
     on the generated resource. 2 tests (one per cause), both confirmed via
     stash: unfixed code emitted the broken native aggregate
     (`count :comment_count, :tags` / `:internal_only`) instead of falling back
     to the `remote(...)` proxy.

  `mix test` green: 286/288 (2/2 doctests, 284/286 tests) — the 2 failures are
  the pre-existing, unrelated `AshRemote.MultiDatalayer.ChangeNotifierTest`
  ProvenCoverage failures, confirmed identical on a clean checkout before any of
  this work (same assertion, same messages, same stacktrace lines). Committed
  `ash_remote@41af024` — one commit, not the suggested security(1,2)/
  correctness(3-6) split: items 1 and 3/4/6 turned out to be genuinely
  interleaved in the same functions (`relationship_line`, `calculation_block`,
  `aggregate_block` each combine identifier validation with the correctness fix
  in the same lines), and forcing a mechanical split would have left a broken,
  non-compiling intermediate commit. Each item is still independently verified
  and independently testable (see the per-item breakdown above and the commit
  message).

- **Severity**: Low (batch)
- **Repo**: ash_remote
- **Verification**: AGENT
- **Source**:
  [20260707 implementation review — L6](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Plan ref**: Workstream R phase R2 items 4, 5, 7, 8
- **Files**: `../ash_remote/lib/mix/tasks/ash_remote.gen.ex`,
  `lib/ash_remote/gen/generator.ex`, `lib/ash_remote/gen/identifier.ex` (new),
  `lib/ash_remote/manifest/loader.ex`

## Defects (unaddressed R2 items)

1. No identifier validation/sanitization: module names, resource names, field
   names, enum values, relationship names, aggregate kinds interpolated raw into
   generated source.
2. Path traversal still possible via
   `Path.join(output, Macro.underscore(module) <> ".ex")` in `ash_remote.gen.ex`
   — output paths must derive only from validated module segments under the
   configured output root.
3. Calc arg `allow_nil?: true` hardcoded instead of generated from manifest
   nullability.
4. `belongs_to` FK type/nullability dropped.
5. `@known_atoms` omits aggregate kinds.
6. Aggregates over many-to-many/private relationships not rejected/proxied.

## Done when

- [x] Malicious-manifest tests (invalid identifiers, traversal paths) are
      rejected with typed errors — fail on unfixed code by generating bad
      files/paths. **Run traversal repros in a temporary output root (or
      dry-run/check mode)** so the "fails by generating bad paths" signal cannot
      write outside the sandbox (spec review); the post-fix assertion includes
      "**no path escaped the configured output root**" — done for identifiers
      (genuinely fails on unfixed code); the path-traversal angle specifically
      is documented as not independently exploitable through the named line (see
      item 2 above), with the containment assertion kept and tested as
      defense-in-depth regardless
- [x] Benign unusual identifiers are quoted or rejected with typed errors, never
      a mid-generation syntax error — rejected (simpler than quoting; both are
      accepted answers per the acceptance criteria)
- [x] FK type/nullability and calc-arg nullability preserved in generated code
- [x] `@known_atoms` covers aggregate kinds (fresh-VM generation of every
      supported aggregate kind succeeds)
- [x] Aggregates over many-to-many/private relationships are proxied or rejected
      with a clear error — never emitted as uncompilable resources
- [x] Full `mix test` green in `../ash_remote`

Note: B2 (aggregate-filter injection) is the blocker-class member of this family
and has [its own task](b2-aggregate-filter-codegen-injection.md).
