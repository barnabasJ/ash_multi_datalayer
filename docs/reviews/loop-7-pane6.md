# Loop 7 — Pane 6: Fresh independent review of 20260707-second-review-fixes

**Scope**: All 48 files in `docs/tasks/20260707-second-review-fixes/` (00-index.md +
every task file). Each load-bearing defect claim and file:line ref verified
against current source in `ash_multi_datalayer` and `../ash_remote`.

**Method**: Every file:line citation was read against actual source. Defect
claims were traced end-to-end (e.g. B3's `tenant_from_filter` regex was
verified against Ash.Filter's `Inspect` protocol implementation in
`deps/ash/lib/ash/filter/filter.ex:5110-5124` and
`deps/ash/lib/ash/query/operator/operator.ex:502-510`; B4's producer/consumer
shape mismatch was verified at both `inbound.ex:156` and
`external_change.ex:72-81`; H2's `upsert/3` `_keys` ignore and
`put_write_action` PK-rebuild were verified at `data_layer.ex:198,230-241`).

**Result**: ~120 source verifications across both repos. All file:line refs,
defect claims, and acceptance criteria checked out **except one**:

---

## FINDING 1 — L2: wrong file:line ref for the flaky live test (MEDIUM)

**File**: `l2-aggregate-fold-notloaded.md`
**Claim**: `example/todo_client/test/todo_client/live_test.exs:92` fails ~70%
of runs (`todo_count == %Ash.NotLoaded{}` instead of `2`).
**Run command in the task**:
`cd example/todo_client && for i in $(seq 1 20); do mix test test/todo_client/live_test.exs:92 || exit 1; done`

**What line 92 actually is**: `} do` — the closing of the test header for
**"toggling a row a different actor already destroyed self-heals instead of
crashing"** (test starts at line 90). This test has no `todo_count` assertion
at all; it toggles a ghost-row and checks self-healing behavior.

**Where the `todo_count` assertion actually lives**:
- `live_test.exs:167` — `assert loaded.todo_count == 3` (expected value is
  **3**, not **2**), inside the test **"relationships, calculation, and both
  aggregates round-trip into assigns"** starting at line 157.
- There is **no** `%Ash.NotLoaded{}` assertion anywhere in `live_test.exs`.
- The `todo_count: 2` assertion the task quotes is in a **different file**:
  `multi_datalayer_test.exs:171` (`assert [%{todo_count: 2}] = ...`), which is
  a pattern-match assertion that would fail with `MatchError`, not produce
  `%Ash.NotLoaded{}`.

**Why this is actionable**: An implementer following the task's run command
would execute `mix test test/todo_client/live_test.exs:92`, which runs the
ghost-row self-healing test — a completely different test that has nothing to
do with aggregate folding or `%Ash.NotLoaded{}`. If that test happens to pass
consistently (it tests self-healing, not aggregate resolution), the
implementer would falsely conclude the L2 fix is verified. The 20-pass gate
would test the wrong behavior entirely.

**Fix**: The most likely intended target is `live_test.exs:167` (the live test
whose `todo_count` assertion could flake to `%Ash.NotLoaded{}` on a cold-cache
fold), with the expected value corrected from `2` to `3`. Alternatively, if
the `2` is intentional, the file should be `multi_datalayer_test.exs:171` —
but that test's failure mode is a `MatchError`, not `%Ash.NotLoaded{}`, so the
`live_test.exs` interpretation is more consistent with the described failure
mode.

**Verification provenance**: The task is marked `AGENT` (traced by a review
agent, not independently re-confirmed). The agent likely confused the test
file or line number.

---

All other tasks verified clean: B1–B7, H1–H5, P6, M1–M11, P1–P4, L1, L3–L13,
P5, PRE, A0, R0, FINAL, deferred-follow-ups, and 00-index.md — every file:line
ref points to the correct code, every defect claim matches current source
behavior, no impossible instructions, no cross-task or intra-file
contradictions.
