# 20260417-Reject-Field-Policies-With-Fallthrough-ADR

**Status**: Accepted **Date**: 2026-04-17 **Deciders**: Barnabas Jovanovics

## Decision Drivers

- Field-level policies (`field_policies` in Ash 3.x) redact per-attribute
  per-actor **after** the datalayer returns rows.
- The subsumption solver reasons about _row-level_ filters, not _actor-level_
  field policies.
- A cached row populated by a broader (e.g. admin) read can contain fields that
  field policies would strip for a less-privileged actor on a later read — so
  serving from cache would bypass the redaction.
- A compile-time rejection is cheaper than a runtime fix and is the
  least-surprising option for the user.

## Context

The security reviewer flagged this as a **blocking** concern: the cache does not
know about actors, and the ledger keys on filter + tenant + loaded_fields but
not on the calling actor or any actor-derived policy fingerprint. Two
first-principles fixes: (a) key the ledger on actor identity (kills the hit
rate, since actors are mostly unique); (b) refuse the configuration altogether.

## Decision

**We will refuse at compile time any resource that uses `field_policies` AND
declares a fall-through read path (`read_order` with more than one layer).
Single-layer reads are always accepted because they bypass the cache entirely
and field policies apply at the action boundary as usual.**

### Implementation Details

Spark verifier `RejectFieldPolicies`:

```elixir
defmodule AshMultiDatalayer.Verifiers.RejectFieldPolicies do
  use Spark.Dsl.Verifier

  def verify(dsl_state) do
    has_field_policies? = Ash.Policy.Info.field_policies(dsl_state) != []
    read_order = AshMultiDatalayer.DataLayer.Info.read_order(dsl_state)

    if has_field_policies? and length(read_order) > 1 do
      {:error,
       "#{inspect(dsl_state)} uses `field_policies` with " <>
       "read_order #{inspect(read_order)}. The multi-datalayer " <>
       "cannot safely serve cached rows to an actor whose " <>
       "field_policies would redact fields the cache holds. " <>
       "Either remove `field_policies`, or set " <>
       "`read_order [#{inspect(List.last(read_order))}]` " <>
       "(single-layer, no cache). See ADR 20260417-reject-" <>
       "field-policies-with-fallthrough."}
    else
      :ok
    end
  end
end
```

## Consequences

### Positive

1. Correctness: no path from "admin cached the row" to "lower-priv actor reads
   redacted fields from cache."
2. Users hit the problem at compile time, not in production.
3. Error message names the concrete fix (drop `field_policies` or shrink
   `read_order` to one layer).

### Negative

1. Users who want cached reads + `field_policies` are blocked. This is the
   honest correctness answer, but it is a feature reduction compared to "seems
   to work."
2. Adding `field_policies` to a previously-cached resource is a
   recompile-and-redeploy event, not a policy-file tweak.

### Mitigations

- Document the limitation prominently in the user guide's "Policy compatibility"
  section.
- Reference this ADR from the verifier error.
- Follow-up RFC (v2+) may introduce actor-keyed ledger entries if adopter demand
  justifies the hit-rate cost.

## Alternatives Considered

### Alternative 1: Include actor identity (or a policy fingerprint) in the ledger key

- Good, because the combination compiles and behaves correctly.
- Bad, because ledger entries become near-unique per actor; hit rate approaches
  zero on anything with per-actor policies.
- Bad, because "policy fingerprint" is a squishy concept; computing it correctly
  under dynamic policies is another correctness risk.

**Why not**: Adds complexity + correctness risk for a hit rate that probably
isn't worth it. Revisit in v2 if real adopters ask.

### Alternative 2: Document the incompatibility but accept the config

- Good, because flexible.
- Bad, because "documented correctness bug" is not a correctness posture we want
  to ship.

**Why not**: Compile-time rejection is cheaper and safer.

### Alternative 3: Runtime check — fall back to primary when actor+field_policies mismatch

- Good, because per-read flexibility.
- Bad, because determining "did this cached entry honour these field policies"
  at read time is the same squishy fingerprint problem with worse latency.

**Why not**: Compile-time rejection forces a simple, auditable configuration
instead of a clever runtime dance.

## Validation

- Compile-time test: a resource with `field_policies` + multi-layer `read_order`
  fails to compile with the expected message.
- Compile-time test: a resource with `field_policies` + `read_order [:l2]`
  compiles successfully.
- A user requests actor-keyed ledgers → track demand, consider v2.

## Links

- [RFC](./ash-multi-datalayer-rfc.md) — security review blocking finding.
- [PRD](./ash-multi-datalayer-prd.md) non-goals section.

---

**Last Updated**: 2026-04-17
