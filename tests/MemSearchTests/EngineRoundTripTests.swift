import Foundation
import Testing
@testable import MemSearch

@Suite("Engine round-trip")
struct EngineRoundTripTests {
    @Test("index then search returns hits")
    func roundTrip() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "# H\nbody".write(to: tmp.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)

        let mem = MemSearch(paths: [tmp], store: MockVectorStore(dimension: 8), embedder: MockEmbeddingProvider(dimension: 8))
        let stats = try await mem.index()
        #expect(stats.filesScanned == 1)
        #expect(stats.chunksAdded > 0)
        let hits = try await mem.search("body", topK: 5)
        #expect(!hits.isEmpty)
    }
}
