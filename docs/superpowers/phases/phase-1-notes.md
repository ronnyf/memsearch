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
