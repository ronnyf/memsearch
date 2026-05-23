import Foundation
import Testing
import GRDB
@testable import MemSearchSQLite

@Suite("SQLite schema migration")
struct SchemaMigrationTests {
    @Test("init creates the expected schema tables")
    func tables() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("schema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("memsearch.db")
        let store = try await SQLiteVectorStore(url: url, dimension: 8)
        let names: [String] = try await store.pool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type IN ('table','view') ORDER BY name")
        }
        #expect(names.contains("chunks_meta"))
        #expect(names.contains("chunks_vec"))
        #expect(names.contains("chunks_fts"))
    }

    @Test("vec0 module is loaded — round-trip embedding insert + MATCH")
    func vec0RoundTrip() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("schema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("memsearch.db")
        let store = try await SQLiteVectorStore(url: url, dimension: 4)

        // Direct vec0 insert (skips chunks_meta because that's Task 20's path).
        // This test only proves the vec0 module is loaded and accepts MATCH queries.
        // 4-float vector [1.0, 0.0, 0.0, 0.0] little-endian.
        let vec = Data([0x00, 0x00, 0x80, 0x3f, 0x00, 0x00, 0x00, 0x00,
                        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00] as [UInt8])
        try await store.pool.write { db in
            try db.execute(sql: "INSERT INTO chunks_vec(rowid, embedding) VALUES (?, ?)",
                           arguments: [1, vec])
        }

        let hits: [Int64] = try await store.pool.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT rowid FROM chunks_vec WHERE embedding MATCH ? ORDER BY distance LIMIT 1
            """, arguments: [vec])
        }
        #expect(hits.count == 1, "vec0 module is loaded and MATCH returns the inserted row")
    }

    @Test("init creates the expected indexes and triggers")
    func indexesAndTriggers() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("schema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("memsearch.db")
        let store = try await SQLiteVectorStore(url: url, dimension: 8)

        let names: Set<String> = try await store.pool.read { db in
            let rows = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type IN ('index', 'trigger')
                AND name NOT LIKE 'sqlite_autoindex%'
            """)
            return Set(rows)
        }
        #expect(names.contains("idx_chunks_meta_source"))
        #expect(names.contains("chunks_meta_ai"))
        #expect(names.contains("chunks_meta_ad"))
        #expect(names.contains("chunks_meta_au"))
        #expect(names.contains("chunks_meta_ad_vec"))  // new orphan-prevention trigger
    }
}
