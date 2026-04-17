# 20260417-Single-Node-V1-ADR

**Status**: Accepted **Date**: 2026-04-17 **Deciders**: Barnabas Jovanovics

## Decision Drivers

- v1 must be shippable to a known-working audience.
- Multi-node coherence is a design problem, not a "throw PubSub at it" problem —
  invalidation ordering, split-brain, write-through-on-one- node-only semantics
  all need thought.
- ETS is node-local by construction; there is no path to "implicitly distribute"
  the cache.
- Shipping a multi-node-unsafe library as if it were multi-node-safe is worse
  than shipping a single-node library that says so loudly.

## Context

The library's layer-1 cache is ETS, which is node-local. Cross-node coherence
has two variants: (1) a write on node A must invalidate caches on nodes B…N
before they serve stale rows; (2) under `:write_behind` (now removed — see
separate ADR), peer nodes don't see the write until the Oban worker runs _and_
their ledger is invalidated. Variant (2) is moot in v1 (no write-behind).
Variant (1) remains, because `write_order` on node A still only touches A's ETS.

## Decision

**We will ship v1 as single-node-only. A compile-time verifier emits a warning
unless the host application explicitly sets
`config :ash_multi_datalayer, :assume_single_node, true` — acknowledging the
limitation. Cross-node coherence is a v2 design problem.**

### Implementation Details

Spark verifier `RejectMultiNode` runs at resource compile time:

```elixir
defmodule AshMultiDatalayer.Verifiers.RejectMultiNode do
  use Spark.Dsl.Verifier

  def verify(dsl) do
    case Application.get_env(:ash_multi_datalayer, :assume_single_node) do
      true -> :ok
      _ -> {:warning,
            "ash_multi_datalayer v1 is single-node-only. Set " <>
            "`config :ash_multi_datalayer, :assume_single_node, true` " <>
            "in your application config to acknowledge this limitation. " <>
            "See ADR 20260417-single-node-v1."}
    end
  end
end
```

A warning, not a hard error — the library can't always tell the deployment shape
at compile time, and a single-node dev machine building a resource that will be
deployed to production is normal. The warning forces the user to set the config
value explicitly, which serves as a documented ack.

Runtime behaviour is unchanged: the cache is local to the node that serves the
request. No PubSub, no distributed state.

## Consequences

### Positive

1. Scope drops: no PubSub design, no distributed invalidation semantics, no
   clustered-test harness in v1.
2. Users are forced to acknowledge the limitation; silent footguns are avoided.
3. v2 has clean ground to design the multi-node story on top of a working
   single-node library rather than simultaneously.

### Negative

1. Multi-node adopters can't use the library as-is in v1.
2. A user who misses the warning and assumes multi-node safety will discover the
   issue in production.
3. The library's audience narrows.

### Mitigations

- `RejectMultiNode` warning text is explicit and points to this ADR.
- Guide includes a "Deployment" section that calls the limitation out at the
  top.
- Runbook calls out "multiple nodes + cache = stale reads on peer nodes" as a
  scenario operators need to understand before enabling `:cache_first`.

## Alternatives Considered

### Alternative 1: Phoenix.PubSub-based invalidation broadcasts in v1

- Good, because multi-node Just Works.
- Bad, because PubSub-based invalidation has its own design problems (message
  ordering under partition, broadcast acknowledgement, pre-invalidation read
  races).
- Bad, because it adds `phoenix_pubsub` (or `:pg`) as a v1 dep.
- Bad, because tests need a clustered harness.

**Why not**: v2 design problem; shouldn't gate v1.

### Alternative 2: Ship silently single-node and hope nobody notices

- Bad, because production incidents.

**Why not**: Obviously.

### Alternative 3: Hard compile error on any non-configured app

- Good, because users can't miss the limitation.
- Bad, because local `mix test` on a dev machine shouldn't need application
  config to compile a resource.

**Why not**: Warnings with forced-ack config is the right trade-off.

## Validation

- The warning is emitted on a resource that hasn't set the ack config →
  validates.
- A user asks for multi-node support → open a separate RFC for v2.

## Links

- [RFC](./ash-multi-datalayer-rfc.md) — architect multi-node concern.
- Related:
  [20260417-no-write-behind-in-v1-adr.md](./20260417-no-write-behind-in-v1-adr.md)
  — write-behind was the worst multi-node problem; cutting it simplifies this
  ADR.

---

**Last Updated**: 2026-04-17
