# Task 22: Divergence sampler

**Phase**: 9 — Divergence sampler **Depends on**: 15 **Blocks**: 32 (dogfood
uses sampler data) **Size**: M

## Objective

When a coverage hit serves a read, with probability `divergence_sampler`
(configured per resource), also issue the same query against the later layer in
`read_order`. Compare the PK sets. If they differ, emit
`[:ash_multi_datalayer, :read, :divergence_detected]` telemetry with the filter
fingerprint and PK delta.

## Out of Scope

- Automatic remediation on divergence (the sampler only detects; the operator
  responds via the runbook).
- Sampling reads that miss coverage (no point; they're already hitting primary).
- Deciding the default sampler rate — that's a separate benchmark task
  (post-release).

## Context

The sampler is the only production signal for "the solver is wrong." Property
tests catch solver bugs on generated input; the sampler catches them on real
input.

## Detailed Steps

### 1. Sampling decision

In `run_query/2`, after a coverage hit has returned rows, before returning to
the caller:

```elixir
def run_query(%Query{} = q, resource) do
  # ... existing hit path ...
  rows = run_against_cache(q, resource)

  if sample?(resource) do
    sample_divergence(q, resource, rows)
  end

  {:ok, rows}
end

defp sample?(resource) do
  rate = AshMultiDatalayer.DataLayer.Info.divergence_sampler(resource)
  :rand.uniform() < rate
end
```

Prefer `:rand.uniform()` over `:rand.uniform(100)` for fractional rates.

### 2. Shadow query against the later layer

```elixir
defp sample_divergence(q, resource, cached_rows) do
  later_layer = last_layer_in_read_order(resource)
  case later_layer.run_query(to_query(q, later_layer), resource) do
    {:ok, primary_rows} ->
      compare_and_emit(resource, q, cached_rows, primary_rows)
    _ ->
      :ok  # primary failed; not a divergence event
  end
end
```

### 3. Set comparison and telemetry

```elixir
defp compare_and_emit(resource, q, cached, primary) do
  cached_pks = MapSet.new(cached, &primary_key/1)
  primary_pks = MapSet.new(primary, &primary_key/1)

  if not MapSet.equal?(cached_pks, primary_pks) do
    delta = %{
      only_in_cache: MapSet.difference(cached_pks, primary_pks) |> Enum.to_list(),
      only_in_primary: MapSet.difference(primary_pks, cached_pks) |> Enum.to_list()
    }

    :telemetry.execute(
      [:ash_multi_datalayer, :read, :divergence_detected],
      %{cache_count: MapSet.size(cached_pks), primary_count: MapSet.size(primary_pks)},
      %{
        resource: resource,
        tenant: q.tenant,
        filter_fingerprint: AshMultiDatalayer.Telemetry.fingerprint(q.filter),
        pk_delta: delta
      }
    )
  end
end
```

### 4. Configuration sanity

- `divergence_sampler: 0.0` → never sample.
- `divergence_sampler: 1.0` → always sample.
- Default (set in the DSL schema): `0.01`.

## Files to Create/Modify

- `lib/ash_multi_datalayer/data_layer.ex` — sampler hook in `run_query/2`.
- `lib/ash_multi_datalayer/divergence.ex` — new; sampler logic.
- `lib/ash_multi_datalayer/telemetry.ex` — add the event name and documentation.
- `test/integration/divergence_sampler_test.exs` — new; seed ETS with stale
  rows, run queries with `divergence_sampler: 1.0`, assert telemetry fires.

## Patterns to Follow

- `:telemetry.execute/3` with `%{...}` measurements and metadata — standard
  pattern for Ash libraries.
- `Ash.Resource.Info.primary_key/1` to get PK attribute names.

## Acceptance Criteria

- [ ] Sampler with rate `0.0` never fires.
- [ ] Sampler with rate `1.0` fires on every hit.
- [ ] When cache and primary return identical PK sets: no `:divergence_detected`
      telemetry.
- [ ] When cache has a row primary doesn't: `:divergence_detected` fires with
      `only_in_cache` populated.
- [ ] When primary has a row cache doesn't: `:divergence_detected` fires with
      `only_in_primary` populated.
- [ ] Metadata includes `resource`, `tenant`, `filter_fingerprint`, `pk_delta`.
- [ ] Measurements include both PK counts.
- [ ] If the shadow primary query fails, no telemetry fires and the original
      return value is unaffected.

## Definition of Done

- [ ] Code compiles with no warnings
- [ ] Tests pass (new + existing)
- [ ] `mix dialyzer` clean
- [ ] Acceptance criteria verified

## Verification

```bash
cd /home/joba/sandbox/ash_multi_datalayer
mix test test/integration/divergence_sampler_test.exs
```

## Notes

- **Don't let the sampler change caller-visible behaviour.** On divergence,
  still return the cached rows to the caller; detection is orthogonal to
  remediation.
- **Sampler errors are silent** — if the primary query fails, we log to
  telemetry `:read, :miss` (as normal) but don't treat it as divergence.
- **Performance**: sampling doubles the cost of the sampled read path. At 1 %
  default, overhead is ≤ 1 % — but some workloads may want to lower the default.
- Filter fingerprint must be PII-safe (structural hash; no raw values). See the
  fingerprint helper in the telemetry module.
