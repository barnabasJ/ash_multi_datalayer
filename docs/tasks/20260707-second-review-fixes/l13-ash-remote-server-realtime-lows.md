# L13 — ash_remote server/realtime LOWs: manifest auth, revocation, refetch amplification, stale docs

- **Status**: DONE
  1. **Manifest schema disclosure — configurable auth hook added (not just
     documented)**: `AshRemote.Server.Router`'s `__using__/1` gained an opt-in
     `manifest_auth:` option — a module Plug (`{module, opts}` or a bare module)
     run immediately before `GET /manifest.json` is served; a halted conn stops
     the manifest from being returned, the same as any other Plug pipeline
     stage. `/rpc/run`/`/rpc/validate` are unaffected. The router's moduledoc
     also states the **explicit, accepted default** (unauthenticated is
     intentional — schema disclosure, not data disclosure, the same posture as
     publishing a GraphQL schema/OpenAPI spec for client generation) so the
     decision isn't a vague "documented" tick. 5 tests confirm: default router
     serves unauthenticated; the new `manifest_auth:` router denies with
     no/wrong header, serves with the right one, and leaves `/rpc/run`
     unaffected — the 2 denial tests confirmed via stash to fail (the option
     didn't exist) on unfixed code.
  2. **Revocation semantics documented** (`Server.Socket`'s moduledoc, new
     "Revocation is join-time-snapshot, not live" section): explains the
     per-record read-policy filter is a join-time snapshot never re-evaluated
     against a later authorization change, why `id/1` defaults to `nil` (no
     `Endpoint.disconnect/3` target by default), and exactly how to close the
     gap (override `id/1` to return an actor-derived string, then call
     `disconnect/3` from wherever the host app performs revocation). Anything
     beyond documentation is out of scope here per the task's own framing —
     recorded at [deferred-follow-ups.md](deferred-follow-ups.md) entry 5.
  3. **Refetch amplification — measured, deferral activated (not
     pre-deferred)**: traced the call path (`handle_out/3` → `visible?/2` →
     `refetch_visible?/4`) and confirmed genuine O(N) DB-read amplification per
     qualifying write for a topic with N subscribers — Phoenix's
     `intercept(["notification"])` dispatches one `handle_out/3` per subscriber
     independently, with no shared state between them. A "simple" shared cache
     was evaluated and rejected: naively keying by `(resource, pkey)` alone
     (ignoring the actor) would leak visibility across subscribers with
     different read-policy outcomes for the same record — a security regression,
     not a perf win. A safe version (shared record fetch, per-subscriber
     authorization against it) is a genuine new stateful component with its own
     invalidation/TTL design, not a small change achievable under this task.
     Deferred-follow-ups.md entry 6's condition (attempt the simple cache, or
     record the measured amplification) is now satisfied — full analysis
     recorded there.
  4. **`connect_params` doc-comment consistency** — confirmed already fixed in
     the tree (`realtime/connection.ex:29-30` and `:170-172` both correctly
     state "evaluated once, in `init/1`, not per connect/reconnect"). No further
     action.

  `mix test` green in `../ash_remote` (229/231 — the 2 remaining failures are
  the same pre-existing, unrelated `ChangeNotifierTest` issue noted throughout
  this tracker).

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
