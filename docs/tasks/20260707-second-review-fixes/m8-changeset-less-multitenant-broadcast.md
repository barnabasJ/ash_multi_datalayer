# M8 — Changeset-less multitenant broadcast is unjoinable

- **Status**: OPEN
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
