# L13 — ash_remote server/realtime LOWs: manifest auth, revocation, refetch amplification, stale docs

- **Status**: OPEN
- **Severity**: Low (batch — security-posture docs + perf follow-up)
- **Repo**: ash_remote
- **Source**:
  [second-review LOW findings](../../reviews/20260706-second-review-findings.md);
  added per
  [task-coverage review F10](../../reviews/20260707-second-review-fixes-task-coverage-review.md)
- **Plan ref**: Workstream R phases R1 items 4–5, R4 items 4–5

## Defects

1. **Unauthenticated `GET /manifest.json`** schema disclosure
   (`server/router.ex:64`). Document mounting behind auth, or add a configurable
   hook if the server boundary supports it. (Plan R1 item 4.)
2. **Join-time-snapshot subscriptions with no revocation path** — the join-time
   read-scope assignment is at `channel.ex:49`, and the default
   `socket id/1 → nil` (which prevents `Endpoint.disconnect` from ever targeting
   a session) lives at `server/socket.ex:89-90` (pass-5 review — the second half
   of the revocation posture). A deactivated user keeps receiving rows until
   they disconnect. Document current semantics; add a server hook only if it
   doesn't change the public channel contract. (Plan R1 item 5; more than that
   is in [deferred-follow-ups.md](deferred-follow-ups.md).)
3. **Per-subscriber DB refetch amplification** on `:unknown` filter evaluation
   (`channel.ex:87,143`) — N subscribers × M writes/s. Add a shared
   per-resource/per-PK refetch cache only if simple; otherwise record the
   benchmark-backed follow-up. (Plan R4 item 4.)
4. ~~**Stale `connect_params` doc comment**~~ — **FIXED in the uncommitted
   working tree** (pass-2 review verified: `connection.ex:29` and `:170` are now
   consistent). Remaining work: none beyond confirming during the docs sweep.
   (Plan R4 item 5.)

## Done when

- [ ] Manifest schema disclosure resolved one of two ways (pass-7 — the default
      `router.ex:64-68` still serves `/manifest.json` with no auth): EITHER add
      a configurable auth hook/plug option with a test, OR make it an **explicit
      documented decision** that the default unauthenticated manifest route is
      accepted (state the accepted exposure) — not a vague "documented" tick
- [ ] Revocation semantics documented where channel consumers will read them
- [ ] Refetch amplification: cache added with a test, or follow-up recorded in
      deferred-follow-ups.md **with the measured amplification** — the deferral
      entry there is conditional on this measurement; deferring without it is
      not a completion path
- [ ] `connect_params` doc-comment consistency confirmed (already fixed in tree)
- [ ] Full `mix test` green in `../ash_remote`
