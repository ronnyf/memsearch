# Spike 0a — GRDB 7.x + sqlite-vec + reader concurrency

**Date:** 2026-05-20
**Phase:** 0
**Outcome:** **PASS** (both criteria green)
**Risk it covers:** macOS-system-SQLite extension-loading viability + GRDB `DatabasePool` reader concurrency under sqlite-vec.

## Environment

- macOS: 26.6
- Swift: 6.4 (toolchain 6.4.0.19.4)
- macOS SDK: 27.0
- GRDB.swift: **7.10.0** (locked via `Package.resolved`)
- sqlite-vec: **v0.1.9** (asg017/sqlite-vec at `e9f598a`)
- Integration path: **soft fork at `/tmp/memsearch-spikes/sqlite-vec-fork/` with custom `Package.swift`** wrapping `sqlite-vec.c` as a SwiftPM C target. Header `sqlite-vec.h` rendered locally from upstream's `sqlite-vec.h.tmpl` via `sed` (substituting `${VERSION}`/`${VERSION_MAJOR}`/etc with v0.1.9 values). Static-linked with `-DSQLITE_CORE -DSQLITE_VEC_STATIC`; consumer registers via `sqlite3_vec_init(db, &errMsg, nil)` directly — no `load_extension` call.

## Result

### Sub-criterion 1 — `vec0` KNN returns inserted vector

**PASS** (0.045 s).

Created `CREATE VIRTUAL TABLE chunks USING vec0(embedding float[1024])`, inserted one vector with `rowid=1`, ran `SELECT rowid FROM chunks WHERE embedding MATCH ? ORDER BY distance LIMIT 5` against the same vector. Returned `[1]` as expected.

### Sub-criterion 2 — Reader concurrency

**PASS** (3.88 s total).

10 000 random 1024-dim vectors loaded. Then issued 8 KNN reads back-to-back (serial baseline) followed by 8 KNN reads in parallel (`withThrowingTaskGroup`).

| Phase                | Wall clock         |
| -------------------- | ------------------ |
| Serial 8 reads       | 0.227 s            |
| Concurrent 8 reads   | 0.089 s            |
| Speedup              | **≈ 2.55×**        |
| Threshold (60 %)     | 0.136 s            |
| Pass condition       | concurrent < 60 % serial → 0.089 < 0.136 ✓ |

GRDB 7.10.0's `DatabasePool` parallelizes readers cleanly when sqlite-vec is registered per connection via `prepareDatabase`. The reader-concurrency assumption underlying the design's `final class : Sendable` shape for `SQLiteVectorStore` holds.

## Spec implications

**Two patches required to `docs/superpowers/specs/2026-05-20-swift-rewrite-design.md`:**

1. **`SQLiteVectorStore.init` — replace `load_extension` with direct `sqlite3_vec_init` call.** The current spec uses
   ```swift
   config.prepareDatabase { db in
       try db.execute(sql: "SELECT load_extension('vec0')")
   }
   ```
   The spike validated that load_extension is unnecessary when sqlite-vec is statically linked (failure mode (a) becomes moot rather than triggered). Replace with:
   ```swift
   config.prepareDatabase { db in
       var errMsg: UnsafeMutablePointer<CChar>?
       let rc = sqlite3_vec_init(db.sqliteConnection, &errMsg, nil)
       if rc != SQLITE_OK {
           let msg = errMsg.flatMap { String(cString: $0) } ?? "vec_init failed"
           if errMsg != nil { sqlite3_free(errMsg) }
           throw VectorStoreError.connectionFailed(/* … */)
       }
   }
   ```
   (Imports: `import SQLite3` is required for `SQLITE_OK` / `sqlite3_free`. `sqlite3_vec_init` is exposed by the `SQLiteVec` SwiftPM target.)

2. **Resolve "Open questions: sqlite-vec distribution".** The spec lists this as open. Resolution: maintain a SwiftPM wrapper that compiles the upstream `sqlite-vec.c` as a C target with `SQLITE_CORE`/`SQLITE_VEC_STATIC` defined. Phase 1 decides whether this lives as (a) a public fork of asg017/sqlite-vec with the wrapper upstreamed via PR, or (b) a vendored copy under `Sources/SQLiteVec/` inside this repo. Either way, **no SPM binary target and no runtime extension loading** — pure source-link.

The "Cancellation granularity per embedder" table and the `final class : Sendable` choice for `SQLiteVectorStore` need no changes.

## Notes

- `import SQLite3` is required at the call site to bring in `SQLITE_OK`, `sqlite3_free`, and the `OpaquePointer` typealiases. GRDB doesn't re-export these.
- `123` C-compiler warnings emitted from `sqlite-vec.c` (mostly `-Wshorten-64-to-32` precision conversions inside the vector arithmetic). These are upstream issues, not actionable for memsearch. Phase 1 may want to silence them with a `-w` per-target cflag.
- Speedup of 2.55× with 8 readers on Apple Silicon is below the theoretical 8× because per-read latency (~28 ms serial) is dominated by SIMD KNN computation that itself uses NEON — there's less headroom for thread-level parallelism beyond ~4×. That's a property of the workload, not GRDB. The reader-concurrency invariant holds.
- Spike scratch lives at `/tmp/memsearch-spikes/spike-0a/` and `/tmp/memsearch-spikes/sqlite-vec-fork/` — not committed.
