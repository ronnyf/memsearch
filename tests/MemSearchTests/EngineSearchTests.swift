import Foundation
import Testing
@testable import MemSearch

@Suite("Engine.search")
struct EngineSearchTests {
    @Test("delegates to store.hybridSearch")
    func delegates() async throws {
        let store = MockVectorStore(dimension: 8)
        let embedder = MockEmbeddingProvider(dimension: 8)
        let mem = MemSearch(paths: [], store: store, embedder: embedder)

        let chunk = Chunk(id: ChunkID("z"), source: URL(fileURLWithPath: "/x.md"),
                          heading: "h", headingLevel: 1, startLine: 1, endLine: 1,
                          content: "x", contentHash: ChunkID.contentHash(for: "x"))
        let canned: [SearchHit] = [SearchHit(chunk: chunk, score: 0.9, denseScore: 0.9, bm25Score: nil)]
        await store.setCannedHits(canned)

        let hits = try await mem.search("hello", topK: 3)
        #expect(hits == canned)
        #expect(embedder.callCount == 1)
    }

    @Test("EmbeddingError lifts to MemSearchError.embedding")
    func liftsEmbedding() async {
        let store = MockVectorStore(dimension: 8)
        let embedder = MockEmbeddingProvider(dimension: 8, injectedFailures: ["q": .authenticationFailed])
        let mem = MemSearch(paths: [], store: store, embedder: embedder)
        await #expect(throws: MemSearchError.self) { _ = try await mem.search("q") }
    }
}
