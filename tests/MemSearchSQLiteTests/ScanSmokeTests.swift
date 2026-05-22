import Foundation
import Testing
import GRDB
import MemSearch
@testable import MemSearchSQLite

@Suite("scan stream")
struct ScanSmokeTests {

    /// Per-test directory captures `*.db-wal` / `*.db-shm` sidecars so
    /// teardown removes everything in one shot. Same pattern as
    /// `CRUDTests.makeTempDir(prefix:)` / Task 19/20 fixes.
    private static func makeTempDir(prefix: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("drains every chunk")
    func drains() async throws {
        let dir = try Self.makeTempDir(prefix: "scan")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await SQLiteVectorStore(
            url: dir.appendingPathComponent("memsearch.db"),
            dimension: 8
        )
        for i in 0..<5 {
            let c = Chunk(
                id: ChunkID("id\(i)"),
                source: URL(fileURLWithPath: "/x.md"),
                heading: "h",
                headingLevel: 1,
                startLine: 1,
                endLine: 1,
                content: "x\(i)",
                contentHash: ChunkID.contentHash(for: "x\(i)")
            )
            _ = try await store.upsert([
                StoredChunk(
                    chunk: c,
                    embedding: try Embedding(
                        values: Array(repeating: 0, count: 8),
                        expectedDimension: 8
                    )
                )
            ])
        }
        var seen = 0
        for try await _ in store.scan(filter: nil) { seen += 1 }
        #expect(seen == 5)
    }
}
