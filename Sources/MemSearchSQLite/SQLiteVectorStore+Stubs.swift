// Stubs to satisfy the `VectorStore` protocol while CRUD / hybridSearch /
// scan / summary methods land in Tasks 20-22. Each task replaces the
// relevant stub with a real implementation; this file disappears entirely
// when Task 22 completes.
import Foundation
import MemSearch

extension SQLiteVectorStore {
    public func upsert(_ records: [StoredChunk]) async throws -> Int {
        throw MemSearchError.unimplemented("upsert: implemented in Task 20")
    }

    public func hybridSearch(_ query: HybridQuery) async throws -> [SearchHit] {
        throw MemSearchError.unimplemented("hybridSearch: implemented in Task 21")
    }

    public nonisolated func scan(filter: SourceFilter?) -> AsyncThrowingStream<Chunk, any Error> {
        AsyncThrowingStream {
            $0.finish(throwing: MemSearchError.unimplemented("scan: implemented in Task 22"))
        }
    }

    public func indexedSources() async throws -> Set<URL> {
        throw MemSearchError.unimplemented("indexedSources: implemented in Task 20")
    }

    public func chunkIDs(forSource source: URL) async throws -> Set<ChunkID> {
        throw MemSearchError.unimplemented("chunkIDs: implemented in Task 20")
    }

    public func delete(ids: [ChunkID]) async throws -> Int {
        throw MemSearchError.unimplemented("delete(ids:): implemented in Task 20")
    }

    public func delete(source: URL) async throws -> Int {
        throw MemSearchError.unimplemented("delete(source:): implemented in Task 20")
    }

    public func summary() async throws -> EngineSummary {
        throw MemSearchError.unimplemented("summary: implemented in Task 22")
    }
}
