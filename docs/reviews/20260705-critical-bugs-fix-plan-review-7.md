# Plan Review (seventh pass) - critical-bugs-fix-plan.md

**Date:** 2026-07-05
**Scope:** latest amended `docs/plans/critical-bugs-fix-plan.md`, after incorporation of pass 4 and cross-checking the concurrently-added pass 6 review.
**Method:** reviewed only residual/new risks introduced or left ambiguous by the latest amendments, against current `Coverage`, `DataLayer`, `Invalidation`, `WriteDispatch`, and `TestSupport` code. This pass does not restate pass 6's Phase 3 findings (`epoch` incarnation/counter pairing and `ensure_table` before snapshot); those remain valid and should be applied alongside the findings below.

## Overall Assessment

The latest plan incorporates the prior pass-1 through pass-4 issues coherently, and pass 6 identifies the remaining epoch-seeding fixes needed in Phase 3. The C4 reconcile scope is explicitly limited, and the `forget!` PK-only probe rule addresses the previous bare-PK ambiguity.

The remaining issues are implementation-contract and acceptance-test precision problems. They are small, but worth fixing before implementation so the resulting code does not regress write-path non-fatality or produce misleading race tests.

## Findings

### Warnings

- **F1. `Coverage.bump_epoch/2` failure semantics are not specified, but it runs after committed writes.**
  `docs/plans/critical-bugs-fix-plan.md:247-259`, `lib/ash_multi_datalayer/write_dispatch.ex:78-105`. The plan makes epoch reads/verifies rescue-safe, but does not say the same for `bump_epoch/2`. `Invalidation.on_write/4` and `drop_all/2` run after the authoritative write has committed; if `:ets.update_counter/4` raises because the table owner died, the supervisor is absent, or the table is mid-restart, an unrescued bump would crash the write path or external notification handler. That is especially risky because Phase 4 also puts physical eviction after the bump. The plan should state that bump failure is non-fatal: treat the epoch as unavailable/moved, continue with best-effort ledger drops and physical eviction, and never fail the already-committed write. A table restart has already erased coverage, so swallowing the bump failure is conservative rather than stale.

- **F2. The C3 race acceptance test conflicts with the follow-up read unless the ledger assertion is ordered precisely.**
  `docs/plans/critical-bugs-fix-plan.md:63-68`, `docs/plans/critical-bugs-fix-plan.md:334-336`. The plan says the full-miss race test should assert the subsequent identical read returns the written value and also that no ledger entry exists for Q at quiescence when the writer wins. If the test performs the subsequent identical read before checking the ledger, that read may legitimately miss, fetch the written value, backfill, and record fresh coverage for Q. The no-entry assertion would then fail even though the fix is correct. Specify the ordering: assert no resurrected/pre-write entry immediately after the raced reader resumes and before any healing read, then perform the follow-up read; or change the later assertion to verify that any post-follow-up entry was recorded by the healing read, not by the stale in-flight reader.

- **F3. Phase 5's private `touch/3` test seam is still underspecified.**
  `docs/plans/critical-bugs-fix-plan.md:474-481`, `lib/ash_multi_datalayer/coverage.ex:157-173`, `lib/ash_multi_datalayer/coverage.ex:269-271`, `lib/ash_multi_datalayer/test_support.ex:22-28`. The plan says to route the deterministic unit test through `AshMultiDatalayer.TestSupport` instead of making `Coverage.touch/3` public, but `TestSupport` currently only exposes `reset!/1`, and the production path calls private `touch/3` immediately inside `Coverage.covers?/3` after selecting entries. There is no deterministic seam to drop the entry between the select and touch without adding one. Specify the seam explicitly: either add a test-only helper under `TestSupport`, expose a narrow `@doc false` function after all, or build a deterministic concurrency test around `covers?/3`. As written, the test instruction is not implementable deterministically.

## Summary

0 critical, 3 warnings, 0 suggestions in this pass, additive to pass 6's Phase 3 findings.

The plan is otherwise implementation-ready from this pass's perspective. Tighten the non-fatal epoch bump contract and the two test specifications before Phase 0/3/5 work starts.

---

**Last Updated:** 2026-07-05
