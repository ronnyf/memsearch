import Foundation
import Testing
@testable import MemSearch

@Suite("index() reduces over indexStream()")
struct EngineReduceInvariantTests {
    @Test("index() == MemSearch.reduce(indexStream() events) on a single engine")
    func reduceMatch() async throws {
        let tmp = makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        try "# A\nbody A".write(to: tmp.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "# B\nbody B".write(to: tmp.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)

        // First engine: drain indexStream into an event array, then call the
        // exposed `reduce` directly. This is what `index()` does internally.
        let mem1 = MemSearch(
            paths: [tmp],
            store: MockVectorStore(dimension: 8),
            embedder: MockEmbeddingProvider(dimension: 8)
        )
        var events: [IndexEvent] = []
        for try await ev in mem1.indexStream() { events.append(ev) }
        let direct = IndexStats.reduce(events)

        // Second engine, fresh state, same fixture: `index()` aggregates internally.
        // Equivalence proves index() = reduce(indexStream()) under the deterministic
        // mock chunker + mock embedder we use here.
        let mem2 = MemSearch(
            paths: [tmp],
            store: MockVectorStore(dimension: 8),
            embedder: MockEmbeddingProvider(dimension: 8)
        )
        let viaIndex = try await mem2.index()
        #expect(viaIndex.filesScanned == direct.filesScanned)
        #expect(viaIndex.chunksAdded  == direct.chunksAdded)
        #expect(viaIndex.chunksRemoved == direct.chunksRemoved)
        #expect(viaIndex.failedFiles  == direct.failedFiles)
    }

    private func makeTempDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("idx-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
