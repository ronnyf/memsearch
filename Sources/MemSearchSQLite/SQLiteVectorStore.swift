import Foundation
import GRDB
import SQLite3
import SQLiteVec
import MemSearch

public final class SQLiteVectorStore: VectorStore, Sendable {
    public nonisolated let dimension: Int
    package let pool: DatabasePool

    public init(url: URL, dimension: Int) async throws {
        precondition(dimension > 0, "SQLiteVectorStore dimension must be > 0")
        var config = Configuration()
        config.prepareDatabase { db in
            var errMsg: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_vec_init(db.sqliteConnection, &errMsg, nil)
            guard rc == SQLITE_OK else {
                let msg = errMsg.flatMap { String(cString: $0) } ?? "sqlite3_vec_init failed (rc=\(rc))"
                sqlite3_free(errMsg)
                throw VectorStoreError.connectionFailed(
                    NSError(domain: "com.memsearch.SQLiteVec", code: Int(rc),
                            userInfo: [NSLocalizedDescriptionKey: msg])
                )
            }
            // Required for the chunks_meta_ad_vec trigger to fire when
            // INSERT OR REPLACE deletes the conflicting row during upsert.
            // SQLite's default is OFF, in which case REPLACE conflict-resolution
            // DELETEs do not fire AFTER DELETE triggers — leaking orphan
            // chunks_vec rows. See https://www.sqlite.org/lang_conflict.html
            // ("delete triggers fire if and only if recursive triggers are
            // enabled"). Per-connection pragma; must be set in prepareDatabase
            // so every reader/writer in the pool inherits it.
            try db.execute(sql: "PRAGMA recursive_triggers = ON;")
        }
        do {
            self.pool = try DatabasePool(path: url.path, configuration: config)
        } catch {
            throw VectorStoreError.connectionFailed(error)
        }
        self.dimension = dimension
        try SQLiteSchema.migrate(pool: pool, dimension: dimension)
    }

    public func close() async {
        // The protocol's `close()` is non-throwing; swallow GRDB errors silently.
        // GRDB's DatabasePool.close() drains the writer + reader pool and is the
        // only path to deterministic teardown (vs. dealloc-time cleanup).
        try? pool.close()
    }
}

// MARK: - CRUD

extension SQLiteVectorStore {

    /// Bulk-upsert chunks + embeddings inside a single write transaction.
    ///
    /// Validation runs first so `dimensionMismatch` cannot leave the store in a
    /// partially-written state. The body uses `INSERT OR REPLACE INTO
    /// chunks_meta(...)` deliberately: the schema's `chunks_meta_ad_vec`
    /// trigger only fires on DELETE, and `INSERT OR REPLACE` rewrites the row
    /// (DELETE + INSERT against the TEXT primary key, allocating a fresh
    /// rowid) which fires the trigger and clears any orphan `chunks_vec` row.
    /// Switching to `UPDATE` or `ON CONFLICT DO UPDATE` would preserve the
    /// rowid and leak the previous embedding — see Task 19's iteration-2
    /// review.
    public func upsert(_ records: [StoredChunk]) async throws -> Int {
        guard !records.isEmpty else { return 0 }
        for r in records where r.embedding.dimension != dimension {
            throw VectorStoreError.dimensionMismatch(
                expected: dimension,
                got: r.embedding.dimension
            )
        }
        do {
            return try await pool.write { db in
                for r in records {
                    try db.execute(sql: """
                        INSERT OR REPLACE INTO chunks_meta(
                            chunk_id, source, heading, heading_level,
                            start_line, end_line, content, content_hash
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        r.chunk.id.rawValue,
                        r.chunk.source.path,
                        r.chunk.heading,
                        r.chunk.headingLevel,
                        r.chunk.startLine,
                        r.chunk.endLine,
                        r.chunk.content,
                        r.chunk.contentHash,
                    ])
                    let rowid: Int64 = try Int64.fetchOne(
                        db,
                        sql: "SELECT rowid FROM chunks_meta WHERE chunk_id = ?",
                        arguments: [r.chunk.id.rawValue]
                    )!
                    try db.execute(
                        sql: "INSERT OR REPLACE INTO chunks_vec(rowid, embedding) VALUES (?, ?)",
                        arguments: [rowid, embeddingBlob(r.embedding.values)]
                    )
                }
                return records.count
            }
        } catch let e as VectorStoreError {
            throw e
        } catch {
            throw VectorStoreError.backendError(error)
        }
    }

    public func delete(ids: [ChunkID]) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        do {
            return try await pool.write { db in
                var n = 0
                for id in ids {
                    if let r: Int64 = try Int64.fetchOne(
                        db,
                        sql: "SELECT rowid FROM chunks_meta WHERE chunk_id = ?",
                        arguments: [id.rawValue]
                    ) {
                        // Explicit chunks_vec DELETE before chunks_meta DELETE
                        // is intentional: the trigger would handle it, but
                        // doing it explicitly keeps single-source-of-truth at
                        // this layer if a future schema change reorders things.
                        try db.execute(
                            sql: "DELETE FROM chunks_vec WHERE rowid = ?",
                            arguments: [r]
                        )
                        try db.execute(
                            sql: "DELETE FROM chunks_meta WHERE chunk_id = ?",
                            arguments: [id.rawValue]
                        )
                        n += 1
                    }
                }
                return n
            }
        } catch {
            throw VectorStoreError.backendError(error)
        }
    }

    public func delete(source: URL) async throws -> Int {
        do {
            return try await pool.write { db in
                let rowids: [Int64] = try Int64.fetchAll(
                    db,
                    sql: "SELECT rowid FROM chunks_meta WHERE source = ?",
                    arguments: [source.path]
                )
                for r in rowids {
                    try db.execute(
                        sql: "DELETE FROM chunks_vec WHERE rowid = ?",
                        arguments: [r]
                    )
                }
                try db.execute(
                    sql: "DELETE FROM chunks_meta WHERE source = ?",
                    arguments: [source.path]
                )
                return rowids.count
            }
        } catch {
            throw VectorStoreError.backendError(error)
        }
    }

    public func indexedSources() async throws -> Set<URL> {
        do {
            let paths: [String] = try await pool.read { db in
                try String.fetchAll(db, sql: "SELECT DISTINCT source FROM chunks_meta")
            }
            return Set(paths.map { URL(fileURLWithPath: $0) })
        } catch {
            throw VectorStoreError.backendError(error)
        }
    }

    public func chunkIDs(forSource source: URL) async throws -> Set<ChunkID> {
        do {
            let ids: [String] = try await pool.read { db in
                try String.fetchAll(
                    db,
                    sql: "SELECT chunk_id FROM chunks_meta WHERE source = ?",
                    arguments: [source.path]
                )
            }
            return Set(ids.map(ChunkID.init))
        } catch {
            throw VectorStoreError.backendError(error)
        }
    }
}

// MARK: - scan + summary

extension SQLiteVectorStore {

    /// Streams every chunk matching the optional source-prefix filter.
    ///
    /// `nonisolated` so stream construction does not require an actor hop —
    /// callers receive the stream synchronously. The body uses
    /// `Task { [pool] in ... }` capturing `pool` directly (avoiding `self`
    /// capture) so the closure remains `@Sendable` without leaking the store.
    ///
    /// Cancellation is observed at two points: once before issuing
    /// `pool.read` (GRDB's await only surfaces cancellation when it returns,
    /// which on a slow query is too late), and once per yielded row so a
    /// consumer that walks away mid-stream stops doing work promptly.
    ///
    /// **Sendable boundary.** `Row` conformance to `Sendable` is explicitly
    /// `unavailable` in GRDB 7.x; mapping `Row` → `Chunk` happens inside the
    /// `pool.read` closure so only `[Chunk]` (Sendable) crosses the actor
    /// boundary. Same pattern as `SQLiteHybridSearch`.
    public nonisolated func scan(filter: SourceFilter?) -> AsyncThrowingStream<Chunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [pool] in
                do {
                    try Task.checkCancellation()
                    let chunks: [Chunk] = try await pool.read { db in
                        let rows: [Row]
                        if let f = filter {
                            rows = try Row.fetchAll(
                                db,
                                sql: "SELECT * FROM chunks_meta WHERE source LIKE ? ORDER BY chunk_id",
                                arguments: [f.prefix.path + "%"]
                            )
                        } else {
                            rows = try Row.fetchAll(
                                db,
                                sql: "SELECT * FROM chunks_meta ORDER BY chunk_id"
                            )
                        }
                        return rows.map(Chunk.make(fromMetaRow:))
                    }
                    for chunk in chunks {
                        try Task.checkCancellation()
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Snapshot-consistent counts inside one `pool.read` — both `COUNT`
    /// expressions execute against the same SQLite snapshot, so concurrent
    /// `upsert` / `delete` calls cannot produce torn `(sources, chunks)`
    /// pairs. See `VectorStore.summary()` doc for the loop-2 review trail.
    public func summary() async throws -> EngineSummary {
        do {
            return try await pool.read { db in
                let row = try Row.fetchOne(db, sql: """
                    SELECT COUNT(DISTINCT source) AS sources, COUNT(*) AS chunks
                    FROM chunks_meta
                """)!
                return EngineSummary(
                    sourceCount: row["sources"] as Int,
                    chunkCount:  row["chunks"]  as Int
                )
            }
        } catch let e as VectorStoreError {
            throw e
        } catch {
            throw VectorStoreError.backendError(error)
        }
    }
}
