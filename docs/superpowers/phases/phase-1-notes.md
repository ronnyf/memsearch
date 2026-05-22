# Phase 1 — Notes (in progress)

**Period:** 2026-05-21 → <end date>
**Status:** in progress

## Decisions

- **sqlite-vec hosting:** vendor under `Sources/SQLiteVec/`. Source pinned to upstream v0.1.9 (commit `e9f598a`). Header rendered locally from `sqlite-vec.h.tmpl` with the v0.1.9 version substitutions. Static-link via `-DSQLITE_CORE -DSQLITE_VEC_STATIC`; consumer calls `sqlite3_vec_init` directly. Public-fork upstream is deferred (post-Phase 7) — vendoring removes the wait.
- **iOS-Simulator compile-gate canonical command:** `xcodebuild build -scheme <Product> -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/derived` (per-product). Recorded in Task 5.

## Surprises

(filled during Phase 1)

## Spec deltas applied

- **`phase1Settings` declaration order in `Package.swift`** (followup to commit `31835e1`): hoisted above the `Package(...)` initializer. The plan and original commit declared it after, causing `swift package dump-package` to emit `"settings": []` for every Swift target — `ApproachableConcurrency` was silently disabled. Fix verified with `swift package dump-package | jq '.targets[] | .settings'` showing one swift setting per target. Plan source patched in the same commit.
- **`VectorStore.summary() async throws -> EngineSummary`** (Task 8): added to the protocol per the plan's Step 1 callout. Doc comment cites the loop-2 review finding (engine-level N+1 raced concurrent indexStream calls). Spec source patched in `2026-05-20-swift-rewrite-design.md` in the same commit. SQLite impl in Task 22; mock impl in Task 9.
- **`RRFTests.twoRetrievers` tolerance** (Task 11, commit `1223f06`): plan asserted `< 1e-3` with comment "both at max." Math says otherwise — input `[[a,b],[b,a]]` puts each item at rank 1 in one retriever and rank 2 in the other (not rank 1 in both), so neither hits the theoretical max. Raw `= 1/61 + 1/62 ≈ 0.03252`; norm `= raw / (2/61) ≈ 0.9919`; `|norm - 1.0| ≈ 0.0081`, within `1e-2` not `1e-3`. Test tolerance loosened to `1e-2` and the comment now shows the math. RRF.fuse implementation itself is verbatim from plan and matches Python `store.py:209`.
- **Task 19 adversarial review fixes** (followup to commit `527ab4a`):
  - `chunks_vec` declared `distance_metric=cosine` (sqlite-vec defaults to L2; semantic search needs cosine).
  - `chunks_meta_ad_vec` AFTER DELETE trigger on `chunks_meta` propagates row deletes to `chunks_vec` (prevents vec0 orphans from `INSERT OR REPLACE` cycle on the chunks_meta TEXT primary key).
  - FTS5 `content_rowid='rowid'` dropped (default behavior; unidiomatic per GRDB FTS5 generator).
  - `SQLiteSchema.migrate(...)` no longer `async` (body is fully synchronous; misleading on the boundary).
  - `SQLiteVectorStore.init` adds `precondition(dimension > 0)` defense.
  - `close()` now calls `try? pool.close()` (was a no-op relying on dealloc).
  - NSError domain reverse-DNS: `com.memsearch.SQLiteVec` (was `sqlite-vec`).
  - `VectorStoreError.unimplemented(String)` case added to remove vocabulary mismatch between SQLiteVectorStore+Stubs.swift (was MemSearchError.unimplemented) and the eventual real impls (which throw VectorStoreError).
  - SchemaMigrationTests: per-test directory captures WAL sidecars; new vec0 round-trip test proves module is loaded; new index/trigger existence test.
  - Sources/MemSearchSQLite/_Module.swift deleted (redundant once real sources exist).

- **Post-Task-22 adversarial review fixes** (followup to commit `1202ce7`):
  - `hybridSearch` now honors `q.filter` (was silently ignored). Filter pushdown applied to both vec0 KNN and FTS5 BM25 subqueries via `chunks_meta.source LIKE ? ESCAPE '\\'`. MockVectorStore.hybridSearch updated to filter likewise.
  - `scan(filter:)` and `hybridSearch` LIKE patterns now use `ESCAPE '\\'` with `%` and `_` escaped via `escapeForLike(...)` helper. Real-world paths containing `_` (e.g. `my_notes/`) no longer false-match.
  - FTS5 query sanitization: `q.queryText` wrapped as a quoted phrase via `toFTS5Phrase(...)` so reserved chars (`"`, `*`, `(`, `:`, etc.) don't trigger FTS5 parser errors.
  - `scan(filter:)` `onTermination` now bridges consumer cancellation to `CancellationError` (matches `MemSearch.indexStream` Task 16 fix). Regression test added.
  - `delete(ids:)` and `delete(source:)` simplified to single batch DELETE on `chunks_meta`; `chunks_meta_ad_vec` trigger handles `chunks_vec` cleanup. Returns `db.changesCount`.
  - Cooperative `Task.checkCancellation()` added to `upsert` per-record loop.
  - `nonisolated` dropped from `scan(filter:)` (redundant on Sendable class).
  - Dead `catch let e as VectorStoreError` clauses removed in `upsert`, `summary`.
  - Tests added: scan consumer-cancel; hybridSearch filter behavior. Sources/MemSearchSQLite/SQLiteVectorStore.swift force-unwrap on summary documented.

- **Post-Task-24 adversarial review fixes** (followup to commit `eaf7022`):
  - Test URLSessions now `invalidateAndCancel()` on defer to prevent per-test session leaks.
  - JSONEncoder/JSONDecoder hoisted to static class lets in OpenAIEmbedder (one allocation per class).
  - Wire DTO edge-case tests added: empty data, missing field, extra-field forward-compat.
  - Count-mismatch postcondition test added — catches contract violations where server returns fewer embeddings than requested.
  - Cooperative `Task.checkCancellation()` added at top of `embed(_:)` to catch pre-network cancellation.

- **Task 27 — CLI executable target renamed** `memsearch` → `MemSearchCLI`:
  - APFS is case-insensitive: SwiftPM's executable target named `memsearch` (lowercase) emits a `memsearch.swiftmodule` that collides with the imported library's `MemSearch.swiftmodule` once `-enable-testing` is on. The plan's `@testable import memsearch` (Tasks 27 + 29) failed under `swift test --filter` with `unable to resolve module dependency: 'memsearch'` and `cannot load module 'memsearch' as 'MemSearch'`.
  - Fix: `cli/Package.swift` now declares an explicit `.executable(name: "memsearch", targets: ["MemSearchCLI"])` product. The executable target name is `MemSearchCLI` (Swift module name, distinct from `MemSearch`); the user-facing binary stays `memsearch`. Source path pinned to existing `Sources/memsearch/` via `path:` to avoid a directory rename.
  - Test imports updated: `@testable import MemSearchCLI`. Tasks 29 + 31 plan templates that use `@testable import memsearch` will need the same swap.

## Items deferred to later phases

(filled during Phase 1)

## iOS-Simulator compile-gate (canonical command)

For each iOS-required library product (`MemSearch`, `MemSearchSQLite`, `MemSearchEmbeddersHTTP`):

```bash
xcodebuild build \
    -scheme <ProductName> \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath /tmp/derived
```

SwiftPM auto-generates one scheme per library product. The CLI executable scheme (`memsearch`) is **excluded** from this gate — the CLI is macOS-only by design.

The `SQLiteVec` C product is iOS-required (transitively via `MemSearchSQLite`); SwiftPM links it through the dependent product, so explicitly building `MemSearchSQLite` covers it.
