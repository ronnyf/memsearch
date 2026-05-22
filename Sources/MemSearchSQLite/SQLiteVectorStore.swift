import Foundation
import GRDB
import SQLite3
import SQLiteVec
import MemSearch

public final class SQLiteVectorStore: VectorStore, Sendable {
    public nonisolated let dimension: Int
    package let pool: DatabasePool

    public init(url: URL, dimension: Int) async throws {
        var config = Configuration()
        config.prepareDatabase { db in
            var errMsg: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_vec_init(db.sqliteConnection, &errMsg, nil)
            guard rc == SQLITE_OK else {
                let msg = errMsg.flatMap { String(cString: $0) } ?? "sqlite3_vec_init failed (rc=\(rc))"
                if errMsg != nil { sqlite3_free(errMsg) }
                throw VectorStoreError.connectionFailed(
                    NSError(domain: "sqlite-vec", code: Int(rc),
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
        try await SQLiteSchema.migrate(pool: pool, dimension: dimension)
    }

    public func close() async { /* GRDB closes on dealloc */ }
}
