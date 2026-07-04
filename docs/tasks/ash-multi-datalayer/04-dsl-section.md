# Task 04: `multi_data_layer` DSL section + `Layer` entity

**Phase**: 2 — DSL + Info + transformer **Depends on**: 03 **Blocks**: 05, 06
**Size**: M

## Objective

Define the `multi_data_layer do ... end` DSL section using
`Spark.Dsl.Extension`, with a nested `layer` entity and section-level options
(`read_order`, `write_order`, `ledger_max_entries`, `divergence_sampler`).
(A `backfill?` option was originally specced here; it was removed 2026-07-03 —
backfilling is always on for multi-layer `read_order`.)

## Out of Scope

- Introspection API (Task 05).
- The transformer that pulls in underlying-layer extensions (Task 06).
- Verifiers (Phase 10).
- Any runtime behaviour.

## Context

This task only builds the compile-time DSL surface: a resource can declare a
valid `multi_data_layer` block and the library accepts it. The parsed state is
consumed by subsequent tasks.

## Detailed Steps

### 1. Define the `Layer` target struct

`lib/ash_multi_datalayer/layer.ex`:

```elixir
defmodule AshMultiDatalayer.Layer do
  @moduledoc """
  An underlying datalayer in a multi-layer configuration.

  Created by the `layer` DSL entity inside `multi_data_layer do ... end`.
  """
  defstruct [:name, :module]

  @type t :: %__MODULE__{
          name: atom(),
          module: module()
        }
end
```

### 2. Build the DSL entity and section

In `lib/ash_multi_datalayer/data_layer.ex`:

```elixir
@layer %Spark.Dsl.Entity{
  name: :layer,
  describe: "An underlying datalayer participating in the layering.",
  target: AshMultiDatalayer.Layer,
  args: [:name, :module],
  schema: [
    name: [type: :atom, required: true, doc: "Identifier for this layer."],
    module: [type: :atom, required: true, doc: "The Ash.DataLayer module."]
  ]
}

@multi_data_layer %Spark.Dsl.Section{
  name: :multi_data_layer,
  describe: "Configure a multi-layer datalayer composition.",
  entities: [@layer],
  schema: [
    read_order: [
      type: {:list, :atom},
      required: true,
      doc: "Order in which layers are consulted for reads."
    ],
    write_order: [
      type: {:list, :atom},
      required: true,
      doc: "Order in which layers receive writes."
    ],
    ledger_max_entries: [
      type: :pos_integer,
      default: 10_000,
      doc: "Hard cap on ledger entries per resource+tenant."
    ],
    divergence_sampler: [
      type: :float,
      default: 0.0,
      doc:
        "Fraction of coverage hits shadow-re-run against a later layer. " <>
          "Opt-in (defaults to off); a probabilistic canary, not a guarantee."
    ]
  ]
}

use Spark.Dsl.Extension, sections: [@multi_data_layer]
```

### 3. Wire into `Ash.DataLayer`

Ensure the module still declares `@behaviour Ash.DataLayer` from Task 03 (there
is no `use Ash.DataLayer`). `@behaviour Ash.DataLayer` and
`use Spark.Dsl.Extension` compose cleanly (see `AshPostgres.DataLayer`).

## Files to Create/Modify

- `lib/ash_multi_datalayer/layer.ex` — new.
- `lib/ash_multi_datalayer/data_layer.ex` — add DSL definitions.
- `test/ash_multi_datalayer/data_layer_dsl_test.exs` — new; compile a test
  resource and assert the parsed DSL state is accessible via
  `Spark.Dsl.Extension.get_entities/2` and `get_opt/5`.

## Patterns to Follow

- `ash/lib/ash/data_layer/ets/ets.ex` — minimal Spark extension pattern.
- `ash_postgres/lib/data_layer.ex` — combined DataLayer + Spark extension
  pattern, with nested entities.

## Acceptance Criteria

- [ ] A test resource with a valid `multi_data_layer` block compiles.
- [ ] `Spark.Dsl.Extension.get_entities(resource, [:multi_data_layer])` returns
      the declared `%Layer{}` entities.
- [ ] `Spark.Dsl.Extension.get_opt(resource, [:multi_data_layer],     :read_order)`
      returns the declared list.
- [ ] Missing `read_order` or `write_order` fails to compile with a Spark error
      mentioning the missing option.
- [ ] An unknown entity inside the block fails with a helpful error.

## Definition of Done

- [ ] Code compiles with no warnings
- [ ] Tests pass (new + existing)
- [ ] Acceptance criteria verified
- [ ] No known regressions introduced

## Verification

```bash
cd ../../..
mix compile --warnings-as-errors
mix test test/ash_multi_datalayer/data_layer_dsl_test.exs
```

## Notes

- Verifiers come in Phase 10 — this task does NOT validate `read_order` /
  `write_order` refer to declared layers. Accept any atoms for now.
- The `schema` types above align with what Spark supports natively; custom types
  are not needed.
- This task is the foundation for everything else — take time to name options
  thoughtfully; renames later are breaking changes.
