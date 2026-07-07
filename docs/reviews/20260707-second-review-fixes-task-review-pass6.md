# Review: `20260707-second-review-fixes/` task files, pass 6

**Date**: 2026-07-07
**Subject**: current task set in
[`docs/tasks/20260707-second-review-fixes/`](../tasks/20260707-second-review-fixes/)
after pass-5 and follow-up task edits.
**Scope**: task executability, sequencing, acceptance-criteria precision, and
targeted source-reference checks in `ash_multi_datalayer` plus sibling
`../ash_remote`.

## Findings

### High - PRE asks for one checkpoint commit across two Git repositories

- **Task refs**: `pre-checkpoint-commit.md:22-26`, `00-index.md:176`
- **Verification refs**: `git rev-parse --show-toplevel` reports
  `/home/joba/sandbox/ash_multi_datalayer` in this repo and
  `/home/joba/sandbox/ash_remote` in the sibling repo.

`PRE` requires "a checkpoint commit of the current MDL + `../ash_remote` `lib/`
state" before any other task. Those paths are in separate Git repositories, so a
single commit cannot contain both trees. As written, the first required task is
not mechanically executable.

**Recommendation**: rewrite `PRE` to require two coordinated checkpoint commits,
one in each repo, or say "checkpoint both repos" with explicit per-repo
branch/commit criteria.

### High - Harness sequencing still permits fixes before their repros

- **Task refs**: `00-index.md:188-202`, `a0-mdl-repro-harness.md:28-32`,
  `r0-ash-remote-repro-harness.md:38-43`
- **Plan refs**: `docs/plans/20260706-second-review-findings-fix-plan.md:55-70`,
  `docs/plans/20260706-second-review-findings-fix-plan.md:123-131`,
  `docs/plans/20260706-second-review-findings-fix-plan.md:427`,
  `docs/plans/20260706-second-review-findings-fix-plan.md:463`,
  `docs/plans/20260706-second-review-findings-fix-plan.md:503`,
  `docs/plans/20260706-second-review-findings-fix-plan.md:530`

The index lists B1/B2, the tenant unit, and B4-B7 before A0/R0, then says the
harness is incremental. A0 repeats the misleading ordering directly: "the harness
is step 4, after B1/B2, the tenant unit, and B4-B7." R0's done criteria require
every ash_remote behavior task to have a repro, while the source plan makes the
R phases depend on R0 repros.

This can lead an implementer to start behavior fixes before writing the relevant
failing repro, which is exactly the failure mode this task set is trying to
prevent.

**Recommendation**: change the recommended order and A0/R0 wording to make "write
the relevant A0/R0 repro first" an explicit prerequisite for each behavior task.
The A0/R0 tasks can still close later after all retained/current repros exist.

### Medium - H2's accept-list scope is internally contradictory and misses the retry path

- **Task refs**: `h2-non-pk-upsert-identity-accept-truncation.md:25-29`,
  `h2-non-pk-upsert-identity-accept-truncation.md:39-49`
- **Source refs**: `../ash_remote/lib/ash_remote/data_layer.ex:198-214`,
  `../ash_remote/lib/ash_remote/data_layer.ex:230-239`,
  `../ash_remote/lib/ash_remote/data_layer.ex:360-368`

H2 says the action-less backfill/replication path is already safe when no
explicit `accept` list exists, but the fix text says "For action-less
backfill/replication update paths, bypass action `accept` truncation." In the
current source, the replicated upsert/update path installs the primary update
action before `input/1`, and `input/1` then truncates to `action.accept` when the
primary action has an explicit accept list. The unsafe case is therefore not truly
"action-less" at the point where truncation happens.

The done criteria also require only the initial non-PK identity lookup to resolve
an existing row. The source has a second lookup after create collision retry; a
fix could thread `keys` through the first lookup and leave the retry path using
primary key only.

**Recommendation**: reword the scope around the actual split: replicated/backfill
updates that must converge all fields must not be truncated by a user action's
accept list, while ordinary action-driven updates still respect `accept`. Add a
done criterion that the create-collision retry path also builds its re-read
filter from `keys`, not only the primary key.

### Medium - M11 cannot distinguish missing `data` from explicit `data: null` without changing `Protocol.parse_run/1`

- **Task refs**: `m11-decoder-crashes-nil-single-object.md:11-12`,
  `m11-decoder-crashes-nil-single-object.md:29-37`,
  `m11-decoder-crashes-nil-single-object.md:45-49`
- **Source refs**: `../ash_remote/lib/ash_remote/protocol.ex:62-63`,
  `../ash_remote/lib/ash_remote/data_layer.ex:280-282`,
  `../ash_remote/lib/ash_remote/decoder.ex:25-35`

M11 requires legitimate `get?` null misses to decode differently from malformed
success responses with missing `data`, but the task's file scope lists only the
decoder/data-layer call site. `Protocol.parse_run/1` currently collapses both
shapes to `{:ok, nil}`. Once that happens, the decoder cannot know whether the
server sent explicit `data: null` or omitted `data` entirely.

**Recommendation**: add `../ash_remote/lib/ash_remote/protocol.ex:62-63` to the
task scope and require tests proving missing `data` becomes a typed protocol
error while explicit `data: null` is accepted only for the `get?` miss shape.

### Medium - M7 acceptance can miss loaded/aliased calculation and aggregate targets

- **Task refs**: `m7-query-calc-aggregate-decode-uncast.md:15-17`,
  `m7-query-calc-aggregate-decode-uncast.md:27-35`
- **Source refs**: `../ash_remote/lib/ash_remote/decoder.ex:61-77`

M7 describes raw placement for ordinary calculation/aggregate decode targets and
requires a date calc plus decimal aggregate to decode as typed values. The source
has separate `place/4` clauses for calculations and aggregates with `load` aliases
that directly `Map.put` the raw wire value. A fix could cast only the default
`:calculations` / `:aggregates` map clauses and still satisfy the current done
criterion while leaving loaded/aliased targets uncast.

**Recommendation**: add acceptance coverage for calculation and aggregate decode
targets with `load`/alias placement, not only the default maps.

### Medium - Tenant consumer tasks do not require the B3 dependency they are supposed to enforce

- **Task refs**: `00-index.md:95-97`, `b3-tenant-from-filter-dead-code.md:81-84`,
  `h5-localoutbox-nil-tenant-model.md:15-18`,
  `m2-context-tenancy-raw-metadata-tenant.md:12-15`,
  `l3-write-through-drain-create-pk-tenant.md:11-14`,
  `p4-global-tenant-invalidation.md:15-18`

The index and B3 say H5/M2/L3/P4 must cite B3 as a dependency and consume the
canonical tenant function verbatim. The consumer task files only list B3 as a
related task or same tenant-unit work; their done criteria do not explicitly
require depending on B3 or using the shared function.

That leaves room for a consumer task to close with a local tenant normalization
fix that passes its own repro but diverges from the canonical partition contract.

**Recommendation**: add explicit `Depends on: B3` wording and a done-when checkbox
to H5, M2, L3, and P4 requiring use of B3's shared canonical tenant function.

### Low - B3's "committed first" criterion conflicts with PRE's checkpoint flow

- **Task refs**: `pre-checkpoint-commit.md:22-26`,
  `b3-tenant-from-filter-dead-code.md:63-65`,
  `b3-tenant-from-filter-dead-code.md:81-84`

PRE requires checkpointing the current untracked `tenant_key.ex` before any other
task. B3 then says it creates and commits the canonical function first. Literally
read, B3's criterion is no longer satisfiable after PRE, because the existing
helper will already have been committed as part of the checkpoint baseline.

**Recommendation**: clarify that B3 must be the first tenant-unit fix after PRE,
or the dependency that lands before H5/M2/L3/P4, not the first commit in the
tracker.

### Low - B1 uses finding `#1` for both open and retained-fixed surfaces

- **Task refs**: `00-index.md:73-77`,
  `b1-rpc-private-calc-aggregate-exfiltration.md:9`,
  `b1-rpc-private-calc-aggregate-exfiltration.md:68-77`

The index says B1's first-run private-attribute `#1` fix is landed-but-untested
and expected to pass on the current tree. B1's header says original finding `#1`
is open, while its checklist also requires retaining the fixed private-attribute
regression. The task body makes the distinction recoverable, but the header and
index labels are easy to misread as a contradiction.

**Recommendation**: name the sub-surfaces explicitly, for example `#1 private
attribute half: fixed-in-tree retained regression` and `#1 private
calculation/aggregate half: OPEN fail-first repro`.

### Low - FINAL assigns changeset-less notification coverage only to A0

- **Task refs**: `final-gates.md:32-33`,
  `m8-changeset-less-multitenant-broadcast.md:40-44`,
  `r0-ash-remote-repro-harness.md:27-31`
- **Plan refs**: `docs/plans/20260706-second-review-findings-fix-plan.md:515-527`,
  `docs/plans/20260706-second-review-findings-fix-plan.md:576-577`

FINAL says tenant-strategy tests, including changeset-less notifications, are
"the A0 items." MDL owns part of that coverage through A0, but ash_remote owns the
changeset-less multitenant broadcast coverage through M8/R0. As written, a final
gate implementer could look only at A0 and miss the remote-side coverage.

**Recommendation**: change the parenthetical to "A0/R0 items" and explicitly cite
M8/R0 for changeset-less multitenant notification coverage.

### Low - L8 omits the fetch helper source range it explicitly requires fixing

- **Task refs**: `l8-rpc-authorize-flag.md:9`, `l8-rpc-authorize-flag.md:19-27`
- **Source refs**: `../ash_remote/lib/ash_remote/server.ex:434-436`

L8's `Files` line lists only `server.ex:349-411`, but the task explicitly
requires fixing helper fetches used by update/destroy. The helper is just outside
the cited range at `fetch!/3`, where `Ash.get!` is called with `subject_opts(opts)`.

**Recommendation**: update the `Files` line to include
`../ash_remote/lib/ash_remote/server.ex:434-436`.

## Summary

- Findings raised: 10 total - 2 High, 4 Medium, 4 Low.
- The remaining issues are mostly sequencing and acceptance-criteria precision.
  The highest-risk items are the impossible cross-repo checkpoint wording and the
  still-ambiguous repro-first harness ordering.
