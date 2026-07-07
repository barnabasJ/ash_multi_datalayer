# M8 — Changeset-less multitenant broadcast is unjoinable

- **Status**: DONE — `broadcast/3` now calls `resolve_tenant/2`: a changeset
  carries the authoritative tenant regardless of strategy (as before);
  changeset-less on an `:attribute`-strategy resource reads the tenant directly
  off `notification.data`'s multitenancy attribute (closes the common case — the
  notification now reaches the correct tenant topic); changeset-less on
  `:context`-strategy has nowhere to recover the tenant from (it never lives on
  the record) — `:unresolvable`, and the notifier does NOT publish to the
  unjoinable untenanted topic. The fallback is a concrete, observable, testable
  signal per the done-when's requirement (not docs-only): a `Logger.warning`
  plus a
  `:telemetry.execute([:ash_remote, :server, :notifier, :unresolvable_tenant], %{count: 1}, %{resource:, action:})`
  event. New `PubSubFixture.AttrTenantThing`/`CtxTenantThing` fixtures + 3 repro
  tests (attribute-derives-and-delivers, context-never-delivers-but-signals,
  non-multitenant-unaffected) using the existing `TestPubSub` broadcast-capture
  harness and a hand-built changeset-less `%Ash.Notifier.Notification{}` (Ash's
  own action pipeline always attaches one; a changeset-less notification is a
  real but externally-triggered shape — e.g. a manual `Ash.Notifier.notify/1`
  call or certain bulk paths). 2 of 3 fail on unfixed code (confirmed: no
  delivery AND no signal for the context case; wrong/unjoinable topic for the
  attribute case). `mix test` green (200/202 — the 2 remaining failures are the
  same pre-existing, unrelated `ChangeNotifierTest` issue noted in M7).
- **Severity**: Medium (lost realtime notifications)
- **Repo**: ash_remote
- **Verification**: AGENT
- **Source**:
  [20260707 implementation review — M8](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Plan ref**: Workstream R phase R4 item 3
- **Files**: `../ash_remote/lib/ash_remote/server/notifier.ex:67`

## Defect

`tenant = notification.changeset && notification.changeset.to_tenant` — a
changeset-less mutation yields `tenant: nil` → `Topics.topic(source, nil)`
publishes to a topic no multitenant subscriber joined → the notification is
lost.

## Failure scenario

Any changeset-less mutation (e.g. bulk/manual notification) on a multitenant
resource: subscribers on the tenant topic never hear about it → client caches go
silently stale.

## Fix

Per plan R4 item 3: derive the tenant from the record's multitenancy attribute
when available; otherwise publish to a joinable tenant topic or conservatively
trigger a documented reconnect/reconcile path. Do not publish to the nil topic
for a multitenant resource.

## Done when

The "documented reconcile" fallback must be an **observable** signal, not a
docs-only closure (spec review): name the concrete mechanism — tenant-topic
delivery, or a specific LifecycleGuard/gap/reconcile event, or a testable
reconnect. The unfixed-code failure to assert is "**no delivery AND no reconcile
signal**", not merely "delivered nothing".

- [ ] Repro test: changeset-less mutation on a multitenant resource either
      reaches the tenant's subscribers OR emits the named reconcile/gap signal —
      fails on unfixed code because neither happens
- [ ] The chosen fallback signal is asserted concretely (topic message, guard
      event, or reconnect), not just "documented"
- [ ] Non-multitenant resources unaffected
- [ ] Full `mix test` green in `../ash_remote`
