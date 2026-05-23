import Foundation
import Testing
@testable import MemSearch

@Suite("Engine cancellation")
struct EngineCancellationTests {
    @Test("indexStream cancellation surfaces as CancellationError")
    func cancels() async throws {
        let tmp = makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        for i in 0..<10 {
            try "# H\nbody \(i)".write(to: tmp.appendingPathComponent("\(i).md"), atomically: true, encoding: .utf8)
        }
        let embedder = MockEmbeddingProvider(dimension: 8, latencyPerBatch: .milliseconds(200))
        let mem = MemSearch(paths: [tmp], store: MockVectorStore(dimension: 8), embedder: embedder)

        let task = Task {
            for try await _ in mem.indexStream() {}
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    private func makeTempDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cancel-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
