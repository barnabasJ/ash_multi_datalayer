# 20260704-Relationship-Aggregates-And-The-Subquery-Boundary-ADR

**Status**: Accepted **Date**: 2026-07-04 **Deciders**: Barnabas Jovanovics

## Decision

`ash_multi_datalayer` continues to **refuse native aggregates** loaded on an MDL
resource (`can?({:aggregate, _}) -> false`,
`can?({:aggregate_relationship, _}) -> false`). This ADR records the _exact_
reason — which is a data-layer-protocol boundary, not a missing capability — so
the limitation can be revisited deliberately rather than rediscovered.

## What actually works today

- **Self aggregates** (`Ash.count(query)`, `Ash.aggregate/…`): run through
  `run_aggregate_query`, which MDL delegates straight to the source of truth.
  Fine.
- **Remote-source aggregates**: `ash_remote`'s generator surfaces a server
  aggregate as a `remote(...)` **calculation** on the client, so it flows
  through the normal calc path (fetched from the source, and filterable/sortable
  via the calc routing). This is why `todo_count`/`completed_count` work in the
  example with no native-aggregate support.

The gap is specifically a **relationship aggregate loaded as a field** (e.g.
`load(:post_count)` where `post_count` is `count :posts`) on an MDL resource
whose source is a SQL layer.

## The exact root cause

A SQL data layer computes a relationship aggregate as a **subquery/join inside
one SQL statement**. ash_sql builds that subquery from the _related_ resource's
query (`ash_sql/aggregate.ex:437`):

```elixir
case Ash.Query.data_layer_query(related_query) do
  %{valid?: true} = related_query -> ...   # then get_subquery/1, which requires an %Ecto.Query{}
```

So ash_sql calls `Ash.Query.data_layer_query` on the related resource and
**assumes the result is an `%Ecto.Query{}`** to splice into the join.
`data_layer_query` dispatches on the related resource's data layer. When that
resource is MDL, it returns MDL's `%AshMultiDatalayer.DataLayer.Query{}` — a
_routing struct_, not Ecto — and ash_sql (which has no knowledge of MDL) cannot
turn it into a join, so the aggregate silently comes back `NotLoaded`. Flipping
`can?` to `true` reproduces exactly this (verified by spike).

### Why MDL can't just return the Ecto query

MDL **is** the data layer for the resource — that is how it intercepts reads to
cache/route them. Its whole contract at build time is to _accumulate the query
abstractly and defer the layer choice until `run_query`_ (coverage decides Ets
vs. source). So `data_layer_query(an MDL resource)` returns the router struct by
construction. MDL _can_ replay that struct into any layer's native query
(`Delegate.to_layer_query(struct, AshPostgres)` yields the Ecto query ash_sql
wants) — but that replay only happens _inside_ `run_query`, after a layer is
chosen.

The tension in one sentence: **a SQL join needs the related query eagerly, as
Ecto, at build time; MDL's entire value is keeping it abstract and deferred.**

There is no clean bridge: the only place to convert is `resource_to_query`,
which has no signal distinguishing "aggregate subquery" from "top-level read".
Returning Ecto there would return it _always_, and every ordinary cached read
would stop routing through MDL. Ash's data-layer protocol has no "give me your
native form for embedding as a subquery" handshake, so this cannot be resolved
in MDL alone or in ash_sql alone.

## Options for revisiting (not chosen now)

1. **Load-and-fold in MDL** (the router-consistent path). Don't push the join
   down at all: intercept the relationship aggregate, load the related **rows**
   through MDL's own read path (cache-covered → fold locally with 0 source
   reads; else source, with remainder reads filling gaps), and fold the value in
   Elixir (count/sum/…). This is exactly how `Ash.DataLayer.Ets` computes
   aggregates, works uniformly for SQL _and_ remote sources, and yields **local
   aggregate evaluation** as a bonus. Tradeoff: it materializes the related
   rows, so it is heavier than a DB-side `COUNT` for very large relationships.
   This is the preferred direction if/when we add aggregate support.
2. **Modeling escape hatch**: leave the _joined-to_ resource as a plain SQL data
   layer (don't wrap it in MDL). Then `data_layer_query(related)` is Ecto and
   the source composes the join natively — at the cost of not caching that
   resource. A documentation note, not code.
3. **Upstream**: a cross-data-layer subquery protocol in Ash/ash_sql ("this
   related resource isn't me; ask it to produce my native query"). Out of our
   hands.

## Consequences

- The `can?` refusal stays (a loud `AggregatesNotSupported` at query build beats
  a silent `NotLoaded`). The rationale is now precise and cited.
- Aggregate needs are met today via remote-calc proxying (remote sources) and
  self-aggregates (all sources). Relationship aggregates on SQL-source MDL
  resources remain unsupported, deliberately.

## Links

- [Fetch-Only-The-Missing-Subset ADR](20260704-fetch-only-the-missing-subset-adr.md)
  — the read spine that a load-and-fold implementation (option 1) would build
  on.
- `lib/ash_multi_datalayer/data_layer.ex` — the `can?({:aggregate, _})` clauses
  and their rationale comment.
