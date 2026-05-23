import Foundation
import Testing
@testable import MemSearch

@Suite("indexStream events")
struct EngineIndexStreamTests {
    @Test("emits .indexed per file then completes")
    func basic() async throws {
        let tmp = makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        try "# A\nbody A".write(to: tmp.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "# B\nbody B".write(to: tmp.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        try "# C\nbody C".write(to: tmp.appendingPathComponent("c.md"), atomically: true, encoding: .utf8)

        let mem = MemSearch(
            paths: [tmp],
            store: MockVectorStore(dimension: 8),
            embedder: MockEmbeddingProvider(dimension: 8)
        )

        var indexedCount = 0
        var removedCount = 0
        var failedCount = 0
        for try await ev in mem.indexStream() {
            switch ev {
            case .indexed: indexedCount += 1
            case .removed: removedCount += 1
            case .failed:  failedCount += 1
            }
        }
        #expect(indexedCount == 3)
        #expect(removedCount == 0)
        #expect(failedCount == 0)
    }

    @Test("emits .removed for orphans on second pass")
    func orphans() async throws {
        let tmp = makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let aURL = tmp.appendingPathComponent("a.md")
        let bURL = tmp.appendingPathComponent("b.md")
        try "# A\nbody A".write(to: aURL, atomically: true, encoding: .utf8)
        try "# B\nbody B".write(to: bURL, atomically: true, encoding: .utf8)

        let store = MockVectorStore(dimension: 8)
        let embedder = MockEmbeddingProvider(dimension: 8)
        let mem = MemSearch(paths: [tmp], store: store, embedder: embedder)

        // First pass: index both files.
        _ = try await mem.index()

        // Remove one file from disk.
        try FileManager.default.removeItem(at: bURL)

        // Second pass: collect events.
        var indexedEvents: [IndexEvent] = []
        var removedEvents: [IndexEvent] = []
        var failedEvents: [IndexEvent] = []
        for try await ev in mem.indexStream() {
            switch ev {
            case .indexed: indexedEvents.append(ev)
            case .removed: removedEvents.append(ev)
            case .failed:  failedEvents.append(ev)
            }
        }

        #expect(indexedEvents.count == 1)
        #expect(removedEvents.count == 1)
        #expect(failedEvents.isEmpty)

        // The remaining .indexed event is for `a.md` with 0 added (already indexed) and 0 removed.
        // Note: compare lastPathComponent because FileManager.enumerator resolves
        // /var/folders → /private/var/folders, so URL equality fails on raw inputs.
        if case .indexed(let url, let added, let removed) = indexedEvents[0] {
            #expect(url.lastPathComponent == aURL.lastPathComponent)
            #expect(added == 0)
            #expect(removed == 0)
        } else {
            Issue.record("expected .indexed event for a.md")
        }

        // The .removed event is for the orphaned `b.md`.
        if case .removed(let url, let chunkCount) = removedEvents[0] {
            #expect(url.lastPathComponent == bURL.lastPathComponent)
            #expect(chunkCount >= 1)
        } else {
            Issue.record("expected .removed event for b.md")
        }
    }

    private func makeTempDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("idx-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
