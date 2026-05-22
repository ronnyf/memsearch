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

## Items deferred to later phases

(filled during Phase 1)
