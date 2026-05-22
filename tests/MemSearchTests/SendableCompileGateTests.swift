import Foundation
import Testing
@testable import MemSearch

private func _gate(_ mem: sending MemSearch<MockVectorStore, MockEmbeddingProvider>) async {
    await Task.detached { _ = mem }.value
}

@Suite("Sendable compile gate")
struct SendableCompileGateTests {
    @Test("MemSearch<MockVectorStore, MockEmbeddingProvider>: Sendable")
    func compiles() async {
        let mem = MemSearch(paths: [], store: MockVectorStore(dimension: 8), embedder: MockEmbeddingProvider(dimension: 8))
        await _gate(mem)
    }
}
