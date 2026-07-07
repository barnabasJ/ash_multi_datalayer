# L6 — Codegen LOWs: identifier validation, path traversal, FK fidelity, calc args

- **Status**: OPEN
- **Severity**: Low (batch)
- **Repo**: ash_remote
- **Verification**: AGENT
- **Source**:
  [20260707 implementation review — L6](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Plan ref**: Workstream R phase R2 items 4, 5, 7, 8
- **Files**: `../ash_remote/lib/mix/tasks/ash_remote.gen.ex`,
  `gen/generator.ex`, loader

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

- [ ] Malicious-manifest tests (invalid identifiers, traversal paths) are
      rejected with typed errors — fail on unfixed code by generating bad
      files/paths. **Run traversal repros in a temporary output root (or
      dry-run/check mode)** so the "fails by generating bad paths" signal cannot
      write outside the sandbox (spec review); the post-fix assertion includes
      "**no path escaped the configured output root**"
- [ ] Benign unusual identifiers are quoted or rejected with typed errors, never
      a mid-generation syntax error
- [ ] FK type/nullability and calc-arg nullability preserved in generated code
- [ ] `@known_atoms` covers aggregate kinds (fresh-VM generation of every
      supported aggregate kind succeeds)
- [ ] Aggregates over many-to-many/private relationships are proxied or rejected
      with a clear error — never emitted as uncompilable resources
- [ ] Full `mix test` green in `../ash_remote`

Note: B2 (aggregate-filter injection) is the blocker-class member of this family
and has [its own task](b2-aggregate-filter-codegen-injection.md).
