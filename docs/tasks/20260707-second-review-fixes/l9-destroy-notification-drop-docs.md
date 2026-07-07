# L9 — Undecidable destroy notifications are dropped — document the staleness class

- **Status**: OPEN
- **Severity**: Low (documentation / LifecycleGuard coverage)
- **Repo**: ash_remote
- **Verification**: AGENT
- **Source**:
  [20260707 implementation review — L9](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Files**: `../ash_remote/lib/ash_remote/server/channel.ex:140-141`

## Defect

Destroy notifications whose read filter isn't in-memory-decidable are dropped,
stranding subscriber caches until an unrelated resubscribe/gap event. This is
**intentional for security** (don't leak rows the subscriber can't prove they
could see), but it is an undocumented staleness class that the LifecycleGuard
must cover.

## Fix

Document the behavior (server channel docs + client cache guidance) and ensure
the LifecycleGuard reconcile path covers this staleness class (or file the
follow-up if it needs protocol support).

## Done when

> The index's repro-first exemption covers **only** the first checkbox (the
> documentation confirmation). The second checkbox below is NOT docs-only — the
> LifecycleGuard coverage question must be actively resolved or explicitly
> deferred (pass-5 review).

- [ ] Behavior documented where subscribers/operators will find it (docs-only —
      the exempt part)
- [ ] LifecycleGuard coverage confirmed with a test, or the follow-up recorded
      in [deferred-follow-ups.md](deferred-follow-ups.md) (the canonical parked
      list) — this checkbox is not satisfied by documentation alone
- [ ] Full `mix test` green in `../ash_remote`
