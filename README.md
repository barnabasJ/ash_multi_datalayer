# AshMultiDatalayer

An `Ash.DataLayer` that puts multiple data stores behind a single Ash resource
as generic ordered layers (`read_order` / `write_order`). The most common use
is a read-through cache — ETS in front of Postgres — with a coverage ledger
that proves when a filtered read is already fully materialised in an earlier
layer (filter subsumption), row-aware invalidation on writes, a runtime
kill-switch, a divergence sampler, and rich telemetry. The same DSL also covers
non-caching patterns such as tiering, migration mirroring, and composing over a
remote backend.

```elixir
defmodule MyApp.Post do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: AshMultiDatalayer.DataLayer,
    extensions: [AshPostgres.DataLayer]

  multi_data_layer do
    layer :l1, Ash.DataLayer.Ets
    layer :l2, AshPostgres.DataLayer

    read_order  [:l1, :l2]   # try the cache, fall through to Postgres
    write_order [:l2, :l1]   # write Postgres first, then the cache
  end

  postgres do
    table "posts"
    repo  MyApp.Repo
  end
end
```

Reads consult the ETS layer whenever the coverage ledger proves it holds a
superset of the incoming query, and fall through (and backfill) otherwise.
Writes go to the source of truth first, invalidate matching ledger entries, and
then propagate the returned record. No per-action code changes.

## Documentation

- [Guide](docs/guides/ash-multi-datalayer.md) — quick start and how-tos.
- [Technical deep-dive](docs/technical/ash-multi-datalayer.md) — architecture,
  data model, edge cases.
- [Runbook](docs/runbooks/ash-multi-datalayer.md) — operating it in production.
- [Design docs](docs/design/) — PRD, RFC, and ADRs.
- [Example](example/) — a working client/server app composing this library over
  `AshRemote.DataLayer` as a client-side cache.

## Installation

Add `ash_multi_datalayer` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ash_multi_datalayer, "~> 0.1.0"}
  ]
end
```

v1 is single-node only; acknowledge this in `config/config.exs`:

```elixir
config :ash_multi_datalayer, :assume_single_node, true
```
