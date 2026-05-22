import Foundation
import Testing
import GRDB
import MemSearch
@testable import MemSearchSQLite

@Suite("hybridSearch")
struct HybridSearchTests {

    /// Per-test directory captures `*.db-wal` / `*.db-shm` sidecars so
    /// teardown can `removeItem(at:)` the whole directory in one shot.
    /// Same pattern as `CRUDTests.makeTempDir(prefix:)` / Task 19/20 fixes.
    private static func makeTempDir(prefix: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("returns hits with dense + bm25 scores populated")
    func hits() async throws {
        let dir = try Self.makeTempDir(prefix: "hs")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await SQLiteVectorStore(
            url: dir.appendingPathComponent("memsearch.db"),
            dimension: 8
        )

        // Three chunks with one-hot embeddings and distinct content. The
        // query below ([1,0,0,0,0,0,0,0] + "hello world 0") is engineered to
        // make chunk 0 win on BOTH dense (cosine distance 0) and BM25
        // (exact-token match), so RRF should rank it first.
        for i in 0..<3 {
            let chunk = Chunk(
                id: ChunkID(String(format: "id%015d", i)),
                source: URL(fileURLWithPath: "/x\(i).md"),
                heading: "h",
                headingLevel: 1,
                startLine: 1,
                endLine: 1,
                content: "hello world \(i)",
                contentHash: ChunkID.contentHash(for: "hello world \(i)")
            )
            var v = [Float](repeating: 0, count: 8)
            v[i] = 1
            _ = try await store.upsert([
                StoredChunk(
                    chunk: chunk,
                    embedding: try Embedding(values: v, expectedDimension: 8)
                )
            ])
        }

        var qVec = [Float](repeating: 0, count: 8)
        qVec[0] = 1
        let hits = try await store.hybridSearch(
            HybridQuery(
                queryText: "hello world 0",
                queryEmbedding: try Embedding(values: qVec, expectedDimension: 8),
                topK: 3,
                filter: nil,
                rrfK: 60
            )
        )

        #expect(!hits.isEmpty)
        #expect(hits[0].denseScore != nil)
        #expect(hits[0].bm25Score != nil)
        #expect(hits[0].score >= 0 && hits[0].score <= 1)
    }
}
