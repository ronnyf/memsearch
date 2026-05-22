import Foundation
import Testing
import GRDB
@testable import MemSearchSQLite

@Suite("SQLite schema migration")
struct SchemaMigrationTests {
    @Test("init creates the expected virtual tables")
    func tables() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("schema-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try await SQLiteVectorStore(url: url, dimension: 8)
        let names: [String] = try await store.pool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type IN ('table','view') ORDER BY name")
        }
        #expect(names.contains("chunks_meta"))
        #expect(names.contains("chunks_vec"))
        #expect(names.contains("chunks_fts"))
    }
}
