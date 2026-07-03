# Task 19: Writes dispatcher + ledger invalidation

**Phase**: 7 — Row-aware invalidation **Depends on**: 17, 03 **Blocks**: —
**Size**: L

## Objective

Implement `create/2`, `update/2`, and `destroy/2` on
`AshMultiDatalayer.DataLayer`: dispatch the write through `write_order`,
invalidate the coverage ledger row-aware (Task 17), and propagate the
authoritative layer's **returned record** into the remaining layers.

## Out of Scope

- `should_drop?/3` / `on_write/5` internals (Task 17).
- Ledger cap enforcement (Task 20).
- Any asynchronous write path — `:write_behind` is cut from v1
  ([ADR](../../design/20260417-no-write-behind-in-v1-adr.md)).
- Re-recording coverage for the written row (no PK-eq ledger entry on write;
  the next read warms it).
- Cross-layer transactions (`can?(:transact)` handling is Task 28).

## Context

The write path carries the library's second correctness invariant (the first is
the solver's conservative-on-unknown rule). Per PRD FR3.5/FR3.6:

> When a write operation returns, every layer earlier in `read_order` than the
> authoritative layer either already reflects the returned record or holds no
> ledger coverage claiming to cover it.

Two consequences drive the design:

1. **Propagate the returned record, never the changeset.** The authoritative
   (first) layer computes fields the caller's changeset does not have —
   defaults, generated IDs, timestamps, server-side changes. This matters most
   when the authoritative layer is a remote backend (e.g. `AshRemote.DataLayer`
   composed under this library as a client-side cache): the server runs real
   changes and validations, so the only correct cache content is the record it
   returned.
2. **Invalidate before upserting.** FR3.4 lets a non-first-layer failure
   log-and-succeed. That is only safe if the matching ledger entries were
   already dropped when the upsert fails — the failure then degrades to a
   coverage miss (fall-through to the source of truth), never a stale read.

## Detailed Steps

### 1. Dispatch shape

```elixir
@impl true
def create(resource, changeset), do: dispatch(resource, changeset, :create)

@impl true
def update(resource, changeset), do: dispatch(resource, changeset, :update)

@impl true
def destroy(resource, changeset), do: dispatch(resource, changeset, :destroy)

defp dispatch(resource, changeset, operation) do
  [authoritative | rest] = write_layers(resource)

  with {:ok, record} <- write_to(authoritative, resource, changeset, operation) do
    row_before = row_before(changeset, operation)
    row_after = row_after(record, operation)

    # Order matters: invalidate FIRST (FR3.6), then propagate (FR3.5).
    Coverage.Invalidation.on_write(resource, tenant(changeset), operation, row_before, row_after)
    propagate(rest, resource, record, operation)

    result(record, operation)
  end
end
```

- Fail-fast on the authoritative layer (FR3.1): its error is returned verbatim;
  no invalidation, no propagation (nothing changed anywhere).
- `write_layers/1` resolves `write_order` names to layer modules via `Info`.
- For `:destroy`, `write_to/4` returns `:ok`; use the changeset's `data` as the
  authoritative record for propagation (delete by PK downstream).

### 2. Row maps for invalidation

Per Task 17's note, `row_before`/`row_after` are **attribute maps**, not Ash
records:

- `:create` — `row_before = nil`, `row_after` from the returned record.
- `:update` — `row_before` from `changeset.data`, `row_after` from the returned
  record (not from `changeset.attributes` — the authoritative layer may have
  changed more than the caller asked).
- `:destroy` — `row_before` from `changeset.data`, `row_after = nil`.

### 3. Propagation into remaining layers

For each layer in `rest`, in `write_order` order:

- `:create` / `:update` — **primary-key upsert of the returned record**. Do not
  re-run the caller's changeset against the layer; build the layer write from
  the record's attributes.
- `:destroy` — delete by primary key; a missing row in the layer is success,
  not an error.

A failure here is logged, emits
`[:ash_multi_datalayer, :write, :layer_failed]` telemetry with the layer name,
and does **not** fail the operation (FR3.4). Do not retry in v1.

### 4. Kill-switch behaviour

When the kill-switch is engaged for the resource (FR6.2):

- Write **only** to the authoritative (first) layer — never "the last layer of
  `write_order`"; for `write_order [:l2, :l1]` that would hit only the cache
  and lose the write.
- Skip propagation into the remaining layers.
- **Still run ledger invalidation.** Entries recorded before the switch was
  flipped would otherwise serve stale coverage the moment the switch is
  re-enabled.

### 5. Telemetry

Emit `[:ash_multi_datalayer, :write, :dispatched]` per operation with the
standard metadata (`resource`, `tenant`, `write_order`) and
`%{duration_us: _, invalidated_count: _}` measurements, alongside Task 17's
`:invalidated` event.

## Files to Create/Modify

- `lib/ash_multi_datalayer/data_layer.ex` — add `create/2`, `update/2`,
  `destroy/2` (or delegate to a new `lib/ash_multi_datalayer/write_dispatch.ex`
  if `data_layer.ex` is getting long).
- `test/ash_multi_datalayer/write_dispatch_test.exs` — new.

## Patterns to Follow

- `Coverage.Invalidation.on_write/5` (Task 17) for the drop pass.
- Read-path backfill (Task 15) for "upsert rows into an earlier layer" — the
  write-path propagation is the same mechanism fed by one record.

## Acceptance Criteria

- [ ] Authoritative-layer failure returns the error; ledger untouched; no
      propagation.
- [ ] Successful write drops matching ledger entries and preserves unrelated
      ones (integration with Task 17).
- [ ] Invalidation happens **before** propagation: with a later layer rigged to
      fail its upsert, the operation still succeeds and the next matching read
      falls through to the source of truth (no stale rows served).
- [ ] Later layers receive the **returned record**: a field computed by the
      authoritative layer (e.g. a DB default) is visible when the next read is
      served from the cache layer.
- [ ] `:destroy` removes the row from all layers; missing-row deletes on later
      layers succeed.
- [ ] Non-first-layer failure logs + emits `:layer_failed` and the operation
      succeeds.
- [ ] Kill-switch engaged: write goes only to the first layer in `write_order`;
      ledger invalidation still runs.

## Definition of Done

- [ ] Code compiles with no warnings
- [ ] Tests pass (new + existing)
- [ ] `mix dialyzer` clean
- [ ] Acceptance criteria verified

## Verification

```bash
cd /home/joba/sandbox/ash_multi_datalayer
mix test test/ash_multi_datalayer/write_dispatch_test.exs
mix dialyzer
```

## Notes

- There is a benign race between invalidation and propagation: a concurrent
  read that coverage-misses in that window falls through to the authoritative
  layer (which already has the write) and backfills fresh rows. Correct, just a
  wasted miss — do not add locking for it in v1.
- The invalidate-before-upsert ordering and the returned-record rule were added
  to the PRD (FR3.5/FR3.6) on 2026-07-03, motivated by composing this library
  over `AshRemote.DataLayer` as a client-side cache. If either rule seems
  inconvenient during implementation, the PRD decision log entry has the
  rationale — do not weaken them.
