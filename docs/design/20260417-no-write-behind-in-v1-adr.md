# 20260417-No-Write-Behind-In-V1-ADR

**Status**: Accepted **Date**: 2026-04-17 **Deciders**: Barnabas Jovanovics

## Decision Drivers

- No existing user, no measurement of current primary-write latency. The
  `:write_behind` latency benefit is a hypothesis, not a measurement.
- Oban write-behind introduces at-least-once duplication risk, DLQ handling,
  cache-row invalidation on permanent failure, and a compile-time verifier —
  each a non-trivial piece.
- Cross-node cache coherence on `:write_behind` requires a PubSub-based
  broadcast design that is its own design problem.
- The simpler library (synchronous writes only) is still the primary thing users
  asked for.

## Context

The original plan included three write strategies: `:write_through`,
`:write_behind` (Oban-backed), `:primary_only`. The skeptic review argued that
`:write_behind` solves a problem the author hasn't measured, and the architect
flagged cross-node coherence as broken. The operator flagged at-least-once
duplication as **blocking**. Together these suggest `:write_behind` is a full
project unto itself; bundling it into v1 inflates scope without proportional
value.

## Decision

**We will remove `:write_behind` from v1. Writes in v1 are synchronous across
layers driven by `write_order`. Users who want asynchronous primary writes wire
Oban (or any queue) in their actions directly. A separate RFC may reconsider
`:write_behind` once the simpler library has real adopters reporting measured
latency problems.**

### Implementation Details

`mix.exs` does not depend on Oban. There is no
`AshMultiDatalayer.WriteBehind.Worker`, no `oban_queue` DSL knob, no
compile-time verifier for Oban-in-path. Writes in v1 route via `write_order`
synchronously; asynchronous options are not an API surface.

## Consequences

### Positive

1. v1 scope drops by an estimated 30–40 %.
2. No at-least-once duplication risk for non-idempotent updates.
3. No DLQ + invalidate-on-permanent-failure machinery.
4. No cross-node coherence design required for v1.
5. Adopters already using Oban retain full control — they wire background writes
   in their actions where the coupling is visible.

### Negative

1. Apps with slow primary writes (triggers, indexes, denormalisation) pay full
   latency on every write. They can still optimise at the action layer; the
   library just doesn't do it for them.
2. A useful future feature is deferred.
3. The library's "write strategy" story is less ambitious than the original
   framing. PRD / RFC narratives must reflect that honestly.

### Mitigations

- Document the escape hatch: "wrap your `AshPostgres.DataLayer`-writing action
  in an Oban job yourself" with a complete example.
- Keep the internal `write_order` abstraction generic so a future
  `:write_behind` layer slot is additive, not a rewrite.

## Alternatives Considered

### Alternative 1: Ship `:write_behind` with all reviewer-required fixes

- Good, because the original ambition is preserved.
- Good, because users get both sync and async strategies in one release.
- Bad, because v1 scope inflates ~40–60 % with idempotency keys, worker
  fingerprinting, DLQ handling, cache-row invalidation on permanent failure,
  Oban verifier, and cross-node coherence design.
- Bad, because the latency benefit is unmeasured against real workloads.

**Why not**: Scope inflation for unmeasured benefit.

### Alternative 2: Ship `:write_behind` via `Ash.Changeset.after_transaction/2` (no Oban)

- Good, because no new dependency.
- Bad, because provides no real latency win over `:write_through` (the primary
  round-trip still happens in the caller path).
- Bad, because no durability across crashes.

**Why not**: Explicitly rejected in the original plan discussion; worse than
`:write_through` for the same caller cost.

## Validation

- Adopters report that synchronous writes are acceptable for their workloads →
  validates.
- An adopter measures primary-write latency as the bottleneck and asks for
  `:write_behind` → reopen as a separate RFC with real numbers.

## Links

- [RFC](./ash-multi-datalayer-rfc.md) — skeptic + architect + operator blocking
  concerns on `:write_behind`.
- [PRD](./ash-multi-datalayer-prd.md) — US2 originally named write-behind;
  updated to reflect sync-only v1.

---

**Last Updated**: 2026-04-17
