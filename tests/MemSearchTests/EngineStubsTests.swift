import Foundation
import Testing
@testable import MemSearch

@Suite("Engine stubs")
struct EngineStubsTests {
    @Test("watch throws .unimplemented")
    func watchUnimplemented() {
        let mem = MemSearch(paths: [], store: MockVectorStore(dimension: 8), embedder: MockEmbeddingProvider(dimension: 8))
        #expect(throws: MemSearchError.self) { _ = try mem.watch() }
    }
    @Test("summarize throws .unimplemented")
    func summarizeUnimplemented() async {
        let mem = MemSearch(paths: [], store: MockVectorStore(dimension: 8), embedder: MockEmbeddingProvider(dimension: 8))
        await #expect(throws: MemSearchError.self) { _ = try await mem.summarize(using: MockSummarizer()) }
    }
}
