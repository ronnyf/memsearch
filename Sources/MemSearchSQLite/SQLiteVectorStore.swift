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
