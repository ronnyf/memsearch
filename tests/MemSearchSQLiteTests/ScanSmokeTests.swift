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

    /// Regression guard: when the consumer task is cancelled mid-iteration,
    /// `for try await` must surface a `CancellationError` rather than
    /// silently completing. AsyncThrowingStream.Iterator.next() returns nil
    /// on consumer cancel by default; the producer's `onTermination` must
    /// bridge cancellation onto the stream via `finish(throwing:)`.
    /// Mirrors the Task 16 indexStream fix.
    @Test("scan consumer-cancel surfaces as CancellationError")
    func consumerCancelSurfacesAsCancellationError() async throws {
        let dir = try Self.makeTempDir(prefix: "scan-cancel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await SQLiteVectorStore(
            url: dir.appendingPathComponent("memsearch.db"),
            dimension: 8
        )

        // Insert enough rows that the consumer-cancel races the per-row
        // `Task.checkCancellation()` rather than the entire stream
        // completing before the cancel arrives.
        for i in 0..<200 {
            let c = Chunk(
                id: ChunkID("id\(i)"),
                source: URL(fileURLWithPath: "/x.md"),
                heading: "h",
                headingLevel: 1,
                startLine: i,
                endLine: i + 1,
                content: "row \(i)",
                contentHash: ChunkID.contentHash(for: "row \(i)")
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

        let task = Task {
            for try await _ in store.scan(filter: nil) {
                try await Task.sleep(for: .milliseconds(50))  // slow consumer
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()

        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}
