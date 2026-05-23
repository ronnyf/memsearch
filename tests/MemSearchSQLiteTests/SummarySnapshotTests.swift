import Foundation
import Testing
import GRDB
import MemSearch
@testable import MemSearchSQLite

@Suite("summary snapshot")
struct SummarySnapshotTests {

    /// Per-test directory captures `*.db-wal` / `*.db-shm` sidecars so
    /// teardown removes everything in one shot.
    private static func makeTempDir(prefix: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("counts (sources, chunks) match inserted data")
    func counts() async throws {
        let dir = try Self.makeTempDir(prefix: "summary")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await SQLiteVectorStore(
            url: dir.appendingPathComponent("memsearch.db"),
            dimension: 8
        )
        // 3 sources × 2 chunks each = 6 chunks total.
        for src in ["/a.md", "/b.md", "/c.md"] {
            for line in [1, 10] {
                let c = Chunk(
                    id: ChunkID("\(src)-\(line)"),
                    source: URL(fileURLWithPath: src),
                    heading: "h",
                    headingLevel: 1,
                    startLine: line,
                    endLine: line + 1,
                    content: "body \(line)",
                    contentHash: ChunkID.contentHash(for: "body \(line)")
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
        }
        let snap = try await store.summary()
        #expect(snap.sourceCount == 3)
        #expect(snap.chunkCount == 6)
    }
}
