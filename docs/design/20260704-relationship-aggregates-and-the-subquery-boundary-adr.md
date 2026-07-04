# 20260704-Relationship-Aggregates-And-The-Subquery-Boundary-ADR

**Status**: Superseded by the load-and-fold implementation (2026-07-04) — see
the update below. **Date**: 2026-07-04 **Deciders**: Barnabas Jovanovics

## Update (2026-07-04): implemented via load-and-fold

The refusal below was lifted. MDL now **folds relationship aggregates** (option
1 in "Options for revisiting"): it computes them itself by loading the related
rows through its own read path — cache when the ledger proves coverage (**0
source reads**), source otherwise — and folding the value in Elixir with
`Ash.DataLayer.Ets.aggregate_value/6` (the exact primitive Ets uses). See
`fold_aggregates/4` in `lib/ash_multi_datalayer/data_layer.ex`.

Because MDL never asks the source to build an in-DB join over an MDL-wrapped
related resource, **the subquery-boundary problem documented below is moot** —
it only ever asks the source to read _rows_, which every data layer can do. So
folding works uniformly for Ets, ash*remote, and SQL sources. (We verified the
prior art empirically: a plain ash_postgres parent counting over a plain Ets
child doesn't silently fail — it \_crashes* with
`KeyError key :__ash_bindings__` when ash_sql gets a non-Ecto related query.
There was never graceful cross-layer aggregation to reuse; folding is the
mechanism.)

Details:

- **On by default**, per-resource `fold_aggregates?` and per-aggregate
  `fold_aggregate_overrides` (mirrors `local_evaluation?`). Off → the old loud
  `AggregatesNotSupported`.
- **Soundness** is inherited from the read path, which always returns the
  _complete_ related set before the fold; coverage only decides cache-vs-source,
  never completeness. This is the aggregate analogue of local calc evaluation
  (Feature B).
- **Never silent**: an overridden aggregate handed to a source that can't
  compute it raises a clear error (`ensure_source_aggregates_resolved!`) instead
  of surfacing `%Ash.NotLoaded{}`.
- **Reproducible aggregates now cross the wire natively**: `ash_remote`'s
  generator emits a server aggregate whose relationship (and any mirrorable
  filter) can be reproduced on the client as a _native_ `count :rel, …` (not a
  `remote(...)` proxy calc), so the cache can fold it. The example showcases
  both paths at once — `todo_count` folded locally (0 RPC on reload),
  `completed_count` opted out and forwarded to the server.
- **Tradeoff** (unchanged from option 1): an uncovered aggregate materialises
  the related rows rather than issuing a bare `COUNT`. A per-source optimisation
  (forward a bare count to sources that can produce one cheaply) is future work.

The original analysis is retained below for the root-cause record.

## Decision (superseded)

`ash_multi_datalayer` originally **refused native aggregates** loaded on an MDL
resource (`can?({:aggregate, _}) -> false`,
`can?({:aggregate_relationship, _}) -> false`). This ADR records the _exact_
reason — which is a data-layer-protocol boundary, not a missing capability — so
the limitation could be revisited deliberately rather than rediscovered.

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
one SQL statement**. ash*sql builds that subquery from the \_related* resource's
query (`ash_sql/aggregate.ex:437`):

```elixir
case Ash.Query.data_layer_query(related_query) do
  %{valid?: true} = related_query -> ...   # then get_subquery/1, which requires an %Ecto.Query{}
```

So ash*sql calls `Ash.Query.data_layer_query` on the related resource and
**assumes the result is an `%Ecto.Query{}`** to splice into the join.
`data_layer_query` dispatches on the related resource's data layer. When that
resource is MDL, it returns MDL's `%AshMultiDatalayer.DataLayer.Query{}` — a
\_routing struct*, not Ecto — and ash_sql (which has no knowledge of MDL) cannot
turn it into a join, so the aggregate silently comes back `NotLoaded`. Flipping
`can?` to `true` reproduces exactly this (verified by spike).

### Why MDL can't just return the Ecto query

MDL **is** the data layer for the resource — that is how it intercepts reads to
cache/route them. Its whole contract at build time is to _accumulate the query
abstractly and defer the layer choice until `run_query`_ (coverage decides Ets
vs. source). So `data_layer_query(an MDL resource)` returns the router struct by
construction. MDL _can_ replay that struct into any layer's native query
(`Delegate.to_layer_query(struct, AshPostgres)` yields the Ecto query ash*sql
wants) — but that replay only happens \_inside* `run_query`, after a layer is
chosen.

The tension in one sentence: **a SQL join needs the related query eagerly, as
Ecto, at build time; MDL's entire value is keeping it abstract and deferred.**

> **Correction (2026-07-04): a clean bridge does exist.** This paragraph
> originally claimed the only conversion point is `resource_to_query`, which is
> context-blind, so returning Ecto would break normal reads. That was wrong. It
> overlooked `set_context/3`: `Ash.Query.data_layer_query` calls the data
> layer's `set_context/3` right after the initial query (`ash/query/query.ex`,
> the `Ash.DataLayer.set_context` step), and **ash_sql populates exactly that
> context for the subquery** — `context.data_layer.parent_bindings` +
> `start_bindings_at` (`ash_sql/aggregate.ex:420`). MDL already implements
> `set_context/3` (`data_layer.ex:382`), so it _can_ tell a subquery from a
> top-level read: only the former carries `parent_bindings`. Moreover
> `parent_bindings` **is the parent query's `__ash_bindings__`**, which carries
> the caller's identity: `sql_behaviour` (the calling data-layer module) and
> `context.data_layer.repo` (`ash_sql/bindings.ex:62-64`, `ash_sql.ex:11`). So
> MDL can gate precisely — swap to the caller's Ecto query only when
> `parent_bindings` is present _and_ its `sql_behaviour`/`repo` match MDL's own
> SQL read layer; a normal read (no `parent_bindings`) always gets the routing
> struct and still routes through the cache. See the revised option 3.

The original (superseded) reasoning: the only place to convert is
`resource_to_query`, which has no signal distinguishing "aggregate subquery"
from "top-level read"; returning Ecto there would return it _always_ and every
cached read would stop routing through MDL.

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
3. **Push the join down via `set_context` (viable, scoped to SQL-same-repo).**
   _Reframed from the original "upstream / out of our hands"._ MDL's
   `set_context/3` inspects `context.data_layer.parent_bindings`. When it is
   present (⇒ an aggregate subquery, never a top-level read) and its
   `sql_behaviour` + `context.data_layer.repo` match one of MDL's own SQL read
   layers, MDL builds and returns **that layer's `%Ecto.Query{}`** — delegating
   `resource_to_query` + `set_context` (with the same context, so ash*sql's
   binding handshake lines up) to the SQL layer, and each subsequent build
   callback (`filter`/`sort`/`select`/`add_aggregates`/`limit`/…) to the SQL
   layer while in this passthrough mode. ash_sql then splices the correlated
   subquery natively. Cost: ~a dozen callback clauses; the gate is exact (no
   `parent_bindings` ⇒ routing struct as before). Limits: works **only** when
   the related resource's source is a SQL layer in the **same repo** as the
   parent, and it computes the aggregate **in the database, bypassing the Ets
   cache** — so it is not a 0-RPC-from-cache path but a "correct DB-side
   `COUNT`" path. It does **not** help remote sources. Relationship to option 1:
   folding already makes cross-layer aggregates \_correct* for every source, so
   this is a pure **efficiency optimization** for large SQL-over-SQL
   relationships, gated on top of folding: covered ⇒ fold (0 RPC); uncovered +
   SQL-same-repo + large ⇒ push the join down; uncovered + small ⇒ fold by
   fetching.

## Consequences

_Superseded by the load-and-fold implementation (see the update at the top)._
The original consequences were:

- The `can?` refusal stays (a loud `AggregatesNotSupported` at query build beats
  a silent `NotLoaded`). The rationale is now precise and cited.
- Aggregate needs are met today via remote-calc proxying (remote sources) and
  self-aggregates (all sources). Relationship aggregates on SQL-source MDL
  resources remain unsupported, deliberately.

As implemented, instead: relationship aggregates are **folded** (option 1) and
work for every source; `can?({:aggregate, kind})` is `true` for foldable kinds,
gated by `fold_aggregates?`. Option 3 (push the SQL join down via `set_context`)
remains an unbuilt but viable efficiency optimization for large SQL-over-SQL
relationships.

## Links

- [Fetch-Only-The-Missing-Subset ADR](20260704-fetch-only-the-missing-subset-adr.md)
  — the read spine that a load-and-fold implementation (option 1) would build
  on.
- `lib/ash_multi_datalayer/data_layer.ex` — the `can?({:aggregate, _})` clauses
  and their rationale comment.
