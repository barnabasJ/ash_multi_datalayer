# L9 — Undecidable destroy notifications are dropped — document the staleness class

- **Status**: DONE
  - **Documentation (the repro-exempt checkbox)**: `Server.Channel`'s moduledoc
    gained a new "A known, intentional staleness class: undecidable destroy
    notifications (L9)" section — explains why the drop is deliberate (nothing
    left to re-read to prove visibility once the row is gone; silence over
    disclosure), what triggers it (a read-policy filter referencing data the
    wire payload doesn't carry — typically related-resource or context-dependent
    policies; simple wire-attribute-only policies never hit this path), and
    gives client cache guidance (treat as a bounded staleness window tied to
    resubscribe/refetch cadence, not a guarantee every destroy arrives).
  - **`LifecycleGuard` coverage (actively resolved, not left implicit)**:
    confirmed `LifecycleGuard` does NOT cover this staleness class today — it
    only reconciles on connection-level gap events
    (`:resubscribed`/`:join_denied`), never on a per-notification drop within an
    otherwise-healthy connection. Closing this properly needs a new realtime
    protocol event (carrying `resource`/`tenant`/ `record_pk`) emitted by the
    channel on drop and threaded through `AshRemote.Realtime` to
    `LifecycleGuard` — a genuine wire-protocol change, not a bug fix.
    **Explicitly deferred**, recorded as item 9 in
    [deferred-follow-ups.md](deferred-follow-ups.md) (the canonical parked
    list), with the exact mechanism needed spelled out for whoever picks it up.
  - `mix test` green in `../ash_remote` (docs-only change to `channel.ex`, no
    behavior change — same 2 pre-existing, unrelated `ChangeNotifierTest`
    failures as every other ash_remote task in this tracker, no new failures).
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
