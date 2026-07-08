# M11 — Client decoder crashes on `nil` / single-object read responses

- **Status**: DONE — `Protocol.parse_run/1` now distinguishes
  `%{"success" => true, "data" => nil}` (an explicit null — stays `{:ok, nil}`)
  from `%{"success" => true}` (the `data` key entirely absent — a malformed
  response, now `{:error, [...]}}`, so the decoder never has to guess).
  `Decoder.decode_records/4` gained a `get?:` opt (default `false`) and always
  returns `{:ok, [record]} | {:error, [map()]}`: a bare single object or
  explicit `nil` decodes cleanly ONLY for `get?: true` (one- element list /
  `[]`); for an ordinary read, either shape is a typed protocol error, never
  silently coerced. `get?` is threaded from `context.action.get?`
  (`AshRemote.Server`'s own `get?(action, params)` first clause — same signal,
  same decision). Note: `read_action_name/2` always targets a resource's PRIMARY
  read action regardless of which action a query names, so a non-primary
  `get_by`-style action (e.g. a hand-written `get_by_id`) never actually reaches
  the server as `get?: true` over RPC — only a resource whose PRIMARY read is
  itself `get?: true` does; a genuine end-to-end repro needed a new fixture
  (`Backend.Singleton`/`Client.Singleton`) built specifically that way (this
  `read_action_name/2` behavior is itself a separate, pre-existing limitation,
  out of scope here). 11 repro tests (unit-level `Decoder.decode_records/4` +
  `Protocol.parse_run/1`, plus 2 genuine RPC round-trip tests against
  `Singleton`) fail on unfixed code (confirmed: `FunctionClauseError` for the
  round-trip cases, missing-function/wrong- shape for the unit ones). `mix test`
  green (212/214 — the 2 remaining failures are the same pre-existing, unrelated
  `ChangeNotifierTest` issue noted in M7/M8).
- **Severity**: Medium (server response crashes the caller)
- **Repo**: ash_remote
- **Verification**: AGENT
- **Source**:
  [20260707 implementation review — M11](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Plan ref**: Workstream R phase R3 item 10 (malformed success responses →
  typed errors)
- **Files**: `../ash_remote/lib/ash_remote/decoder.ex:26-32` (called from
  `data_layer.ex:132`); **and `../ash_remote/lib/ash_remote/protocol.ex:62-63`**
  — `parse_run` collapses BOTH `%{"success" => true, "data" => nil}` and
  `%{"success" => true}` (missing `data`) to the same `{:ok, nil}`, so the
  decoder alone cannot tell "explicit null miss" from "malformed missing data".
  Distinguishing them (below) requires a `parse_run` change (pass-6 review).

## Defect

`decode_records/3` has only `%{"results" => ...}` and `is_list` clauses.
`Protocol.parse_run` returns `{:ok, nil}` for `%{"success" => true}` /
`data: null`, and the `get?` read branch returns a bare map or `nil`.

## Failure scenario

A `get? true` primary read (the client always targets the primary read) or a
`data: null` response → `decode_records(nil, ...)` → `FunctionClauseError` out
of `run_query/2` (no rescue). A malformed or malicious server response crashes
the caller instead of degrading.

## Fix

Distinguish the two cases — do NOT blanket-normalize `nil` to success. Because
`parse_run` currently collapses both to `{:ok, nil}`, the distinction must be
made **in `parse_run` (protocol.ex:62-63)**, e.g. keep
`%{"success" => true, "data" => nil}` as a distinct "explicit null" shape and
treat `%{"success" => true}` (no `data` key) as a malformed/framework error —
the downstream decoder cannot recover this once both are `{:ok, nil}`.

1. **Legitimate shapes** decode cleanly: a `get?` read's bare single object →
   single-record decode; a `get?` miss (explicit `data: null` where the protocol
   defines null as "no row") → empty result.
2. **Malformed success shapes** — `{"success": true}` with `data` **missing**,
   or `null` where the protocol requires a list — become **typed protocol
   errors** (plan R3 item 10), never a silent empty result.

## Done when

Assert the **exact return shape** `run_query/2` hands back to the Ash data layer
(spec review) — the data layer expects a list, so a `get?` hit must not return a
bare struct:

- [ ] `get?` single-object hit decodes to a **one-element list** (`[record]`),
      not a bare struct — fails on unfixed code with `FunctionClauseError`
- [ ] Legitimate `get?` miss (explicit `data: null` per protocol) decodes to
      `[]`
- [ ] Malformed success shape with **`data` key absent** returns a typed
      protocol error — asserted as an error, distinct from the explicit-null
      miss (requires the `parse_run` change; test at that layer)
- [ ] **Non-`get?` read with explicit `data: null` (pass-7 Medium)**: an
      ordinary list read whose response is `{"success": true, "data": null}`
      returns a typed protocol error, NOT `[]` — guards against a blanket
      `nil -> []` fix that would silently accept null where a list is required
- [ ] **Non-`get?` read with a bare-object `data` (loop-6)**: an ordinary list
      read whose `data` is a single map (not a list) returns a typed protocol
      error — guards against a blanket `decode_records(map) -> [decode(map)]`
      fix that would silently accept a malformed bare-object list response
- [ ] Full `mix test` green in `../ash_remote`
