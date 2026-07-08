# L7 — Data-layer LOWs: header dedupe, write retries, composite PK, filter/sort encoding

- **Status**: DONE — all 5 defects fixed with genuine fail-first-verified
  regressions (all confirmed via `git stash` to fail on unfixed code for the
  stated reason, then pass fixed):
  1. **Header dedupe** (`data_layer.ex`'s private `request/4` → `request/5`):
     `transport.headers ++ extra_headers` replaced with `merge_headers/2` —
     case-insensitive dedupe by header name. **Precedence: the per-request
     header wins** (actor-derived token or explicit `context:` header) over the
     transport's static config header — recorded rationale: a stale static
     default silently overriding the real caller's identity is the more
     dangerous failure mode than the reverse. Test:
     `test/ash_remote/transport_request_test.exs` — a custom
     `AshRemote.Test.RecordingTransport` observes the actual `%Config{}` headers
     the data layer hands the transport; asserts exactly ONE `authorization`
     header reaches it (never two) and that it's the actor-derived one, plus a
     differently-named static header survives untouched. Confirmed via stash:
     unfixed code sends BOTH `authorization` headers.
  2. **Write-retry scoping**: `request/5` gained a required `idempotent?`
     keyword (every one of the 4 call sites states it explicitly — reads `true`,
     writes `false`) and forces `retry: false` on writes regardless of the
     transport's configured policy. Test: same file — writes
     (create/update/destroy) against a transport configured
     `retry: :safe_transient` are recorded with `retry: false`; a read on the
     same transport keeps `:safe_transient`. Confirmed via stash: unfixed writes
     go out carrying the configured retry.
  3. **Composite-PK crash**: `[pk] = Ash.Resource.Info.primary_key(resource)` in
     `data_layer.ex:372` (`fetch_remote_calculations/5`) and
     `remote_calculation.ex:46,71` replaced with full-primary-key keying — same
     fix pattern as MDL's L1 (`Map.take`/`Map.get` over the whole PK instead of
     single-key destructuring). New public `AshRemote.DataLayer.pk_wire_key/2`
     builds the matching stringified lookup key from either a native record
     (atom keys) or a wire row (string keys), so both sides of the bundle-fetch
     round trip agree. `fetch_remote_calculations/5`'s filter also changed from
     a single- attribute `in:` to `or:` of full-PK equality maps (verified
     directly: `Ash.Filter.parse!(resource, or: [...])` encodes correctly via
     the existing `Filter.encode/1`). New fixture:
     `AshRemote.{Backend,Client}.CompositeItem` (2-attribute PK: `id` +
     `tenant`) with an `AshRemote.RemoteCalculation`-proxied calc, exercised via
     `Ash.load!/3` (the bundled-fetch path). Test:
     `test/ash_remote/composite_pk_test.exs` — confirmed via stash: unfixed code
     raises `MatchError: no match of right hand side value: [:id, :tenant]` at
     `remote_calculation.ex:46`. A second test with two same-tenant,
     different-id records proves the lookup keys by the FULL PK, not a single
     attribute.
  4. **Filter relationship-path scoping**: `predicate/3` in `encode/filter.ex`
     now nests the leaf predicate under each `ref.relationship_path` segment
     (`nest_relationship_path/2`) — `user.name == "Ada"` encodes as
     `%{"user" => %{"name" => %{"eq" => "Ada"}}}` instead of the bare
     `%{"name" => %{"eq" => "Ada"}}`. This is the exact nested-map shape
     `Ash.Query.filter_input/2` already parses natively server-side, so no
     server change was needed. Reachability note: `AshRemote.DataLayer` declares
     `can?({:join, _})` false, so Ash's own query builder already refuses a REAL
     relationship-path filter against a generated/mirrored client resource today
     (confirmed: `Todo |> Ash.Query.do_filter(expr(user.name == "Ada"))` errors
     "not filterable" before a Ref is ever built) — this is a
     defensive/forward-looking fix (and `remote_identity_row/3` bypasses that
     same gate via `Ash.Filter.parse!/2` directly, so the encoder itself is
     still a real boundary). Test: `test/ash_remote/encode_test.exs` —
     hand-built `%Ash.Query.Ref{}` terms (mirroring how M7's tests isolate
     `Decoder.place/4` from an unreachable round trip) confirm single- and
     multi-hop nesting. Confirmed via stash: unfixed code drops the `"user"`
     wrapper entirely.
  5. **Parameterized-calc sort args preserved**: `Encode.Sort.encode/1` now
     emits a LIST (was a comma-joined string) whose entries are plain strings
     for ordinary fields, or `%{"field", "direction", "input"}` maps for a calc
     with non-empty `calc.context.arguments` (mirrors `Encode.Filter`'s
     `calc_arguments/1` — args live in the calc's context, never in the
     `remote(name, %{...}, pk)` custom expression's own static argument
     template). Server (`AshRemote.Server`) dispatch replaced
     `Ash.Query.sort_input/2` with a `resolve_sort/2` wrapper: list entries
     become `{field, {input, direction}}` tuples (the exact shape
     `Ash.Sort.parse_sort/4` already understands from a `handler`-provided
     calc-arg sort), re-atomizing the wire's string-keyed `input` map against
     the calc's own declared argument names (bounded allowlist, no arbitrary
     `String.to_atom/1`) before it reaches
     `Ash.Query.Calculation.from_resource_calculation/3`'s options-schema
     validation. A legacy plain string sort is still passed straight through
     unchanged. Tests: `encode_test.exs` (unit — args preserved in the wire map;
     a truly argument-less calc still encodes as a plain string) AND a new
     end-to-end regression in `remote_load_test.exs` using a new server-side
     EXPRESSION-based parameterized calc, `title_matches_target` (added to
     `test/support/backend/todo.ex` — unlike the pre-existing
     `title_with_prefix`, a module calc that can never be sorted server-side at
     all, this one genuinely is sortable) — sorting by the SAME calc with two
     different `target` args produces two DIFFERENT orderings. Confirmed via
     stash: unfixed code produces the IDENTICAL ordering for both args (the args
     are silently dropped, so the backend evaluates with the same default every
     time) — the strongest of the five discriminators, a real behavior
     difference, not just a shape difference.

  Existing `test/ash_remote/encode_test.exs` `Sort.encode/1` assertions updated
  for the new list-based wire shape (no other consumer assumed the old
  comma-string shape — verified by grep). `mix test`: 286/288 (2/288 doctests
  green, 284/286 tests — the 2 failures are the pre-existing, unrelated
  `AshRemote.MultiDatalayer.ChangeNotifierTest` ProvenCoverage failures named in
  the task's own gate instructions, confirmed present before this work and
  untouched by it).

- **Severity**: Low (batch)
- **Repo**: ash_remote
- **Verification**: AGENT
- **Source**:
  [20260707 implementation review — L7](../../reviews/20260707-second-review-fix-plan-implementation-review.md)
- **Plan ref**: Workstream R phase R3 items 6, 7, 8, 9, 11
- **Files**: `../ash_remote/lib/ash_remote/data_layer.ex:322`,
  `remote_calculation.ex:46,71`, `encode/filter.ex:96`, transport/request
  building

## Defects (unaddressed R3 items)

1. Possible duplicate `authorization` header:
   `transport.headers ++ extra_headers` — static config token and actor token
   both emitted. Dedupe by case-insensitive name with an explicit precedence
   rule.
2. `retry` config applied to non-idempotent write POSTs — scope retries to
   idempotent read/run requests.
3. Composite-PK `[pk] =` crashes in `data_layer.ex:322` and
   `remote_calculation.ex:46,71`.
4. `ref_name/1` drops `relationship_path` (`encode/filter.ex:96`) — filter refs
   become silently unscoped; keep the path or reject such references.
5. Sort on a parameterized calculation drops its arguments.

## Done when

- [x] Header dedupe test with both static and actor tokens that **asserts the
      chosen precedence rule** (which token wins) and case-insensitive duplicate
      names — not merely that a dedupe happened (spec review: a dedupe-happened
      test passes with an arbitrary/unstable winner)
- [x] Write POSTs are not retried; reads still are
- [x] Composite-PK resources exercise the remote-calculation paths without
      `MatchError`
- [x] Relationship-path filter refs encode correctly or error; parameterized
      calc sort preserves args
- [x] Full `mix test` green in `../ash_remote` (286/288 — the 2 known
      pre-existing `ChangeNotifierTest` failures excepted)
