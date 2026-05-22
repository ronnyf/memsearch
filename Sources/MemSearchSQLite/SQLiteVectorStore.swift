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
                    try Task.checkCancellation()
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
        } catch {
            throw VectorStoreError.backendError(error)
        }
    }

    public func delete(ids: [ChunkID]) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        do {
            return try await pool.write { db in
                // Single batch DELETE on chunks_meta. The `chunks_meta_ad_vec`
                // AFTER DELETE trigger (Task 19/20 fix) propagates each row
                // delete to chunks_vec, so we don't iterate or fetch rowids
                // here. `db.changesCount` reports the row count touched by
                // the most recent statement on this connection.
                let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
                try db.execute(
                    sql: "DELETE FROM chunks_meta WHERE chunk_id IN (\(placeholders))",
                    arguments: StatementArguments(ids.map(\.rawValue))
                )
                return db.changesCount
            }
        } catch {
            throw VectorStoreError.backendError(error)
        }
    }

    public func delete(source: URL) async throws -> Int {
        do {
            return try await pool.write { db in
                // Trigger `chunks_meta_ad_vec` cleans chunks_vec; no manual
                // rowid fetch needed.
                try db.execute(
                    sql: "DELETE FROM chunks_meta WHERE source = ?",
                    arguments: [source.path]
                )
                return db.changesCount
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
    /// The body uses `Task { [pool] in ... }` capturing `pool` directly
    /// (avoiding `self` capture) so the closure remains `@Sendable` without
    /// leaking the store. (No `nonisolated` modifier — the class is
    /// `Sendable` and methods are nonisolated by default; matches the
    /// protocol's plain `func scan(filter:)` declaration.)
    ///
    /// Cancellation is observed at two points: once before issuing
    /// `pool.read` (GRDB's await only surfaces cancellation when it returns,
    /// which on a slow query is too late), and once per yielded row so a
    /// consumer that walks away mid-stream stops doing work promptly.
    /// `onTermination` additionally bridges *consumer* cancellation
    /// (caller-task cancel mid-iteration) into a `CancellationError` so the
    /// for-try-await loop surfaces it — without the bridge, the iterator
    /// returns nil on consumer cancel and the loop exits silently. Same
    /// pattern as `MemSearch.indexStream` (Task 16 fix).
    ///
    /// **Sendable boundary.** `Row` conformance to `Sendable` is explicitly
    /// `unavailable` in GRDB 7.x; mapping `Row` → `Chunk` happens inside the
    /// `pool.read` closure so only `[Chunk]` (Sendable) crosses the actor
    /// boundary. Same pattern as `SQLiteHybridSearch`.
    ///
    /// **Filter LIKE escaping.** The `f.prefix.path` value is wrapped via
    /// `escapeForLike(...)` so `_` / `%` / `\` in real-world paths
    /// (e.g. `my_notes/`) are treated as literals under `ESCAPE '\\'`.
    ///
    /// **Materialization.** This implementation materializes the full
    /// result set inside `pool.read` before yielding row-by-row to the
    /// consumer. Memory profile scales linearly with the number of
    /// matching rows × per-Chunk size. Acceptable for v1 memsearch sizes
    /// (<100k chunks); future iterations may switch to `Row.fetchCursor`
    /// for true row-streaming if memory becomes a constraint.
    public func scan(filter: SourceFilter?) -> AsyncThrowingStream<Chunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [pool] in
                do {
                    try Task.checkCancellation()
                    let chunks: [Chunk] = try await pool.read { db in
                        let rows: [Row]
                        if let f = filter {
                            let pattern = escapeForLike(f.prefix.path) + "%"
                            rows = try Row.fetchAll(
                                db,
                                sql: "SELECT * FROM chunks_meta WHERE source LIKE ? ESCAPE '\\' ORDER BY chunk_id",
                                arguments: [pattern]
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
            continuation.onTermination = { reason in
                task.cancel()
                // Bridge consumer-cancellation onto the stream so for-try-await
                // surfaces CancellationError. AsyncThrowingStream.Iterator.next()
                // returns nil on consumer cancel, doesn't throw. Same pattern
                // as MemSearch.indexStream (Task 16 fix).
                if case .cancelled = reason {
                    continuation.finish(throwing: CancellationError())
                }
            }
        }
    }

    /// Snapshot-consistent counts inside one `pool.read` — both `COUNT`
    /// expressions execute against the same SQLite snapshot, so concurrent
    /// `upsert` / `delete` calls cannot produce torn `(sources, chunks)`
    /// pairs. See `VectorStore.summary()` doc for the loop-2 review trail.
    public func summary() async throws -> EngineSummary {
        do {
            return try await pool.read { db in
                // COUNT-only SELECT against a real table always returns
                // exactly one row, so the force-unwrap is safe. Documenting
                // the SQL semantic in-line is cleaner than a defensive
                // throw-path that can never fire.
                let row = try Row.fetchOne(db, sql: """
                    SELECT COUNT(DISTINCT source) AS sources, COUNT(*) AS chunks
                    FROM chunks_meta
                """)!
                return EngineSummary(
                    sourceCount: row["sources"] as Int,
                    chunkCount:  row["chunks"]  as Int
                )
            }
        } catch {
            throw VectorStoreError.backendError(error)
        }
    }
}
