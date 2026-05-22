// Stubs to satisfy the `VectorStore` protocol while scan / summary land
// in Task 22. Each task replaces the relevant stub with a real
// implementation; this file disappears entirely when Task 22 completes.
import Foundation
import MemSearch

extension SQLiteVectorStore {
    public func scan(filter: SourceFilter?) -> AsyncThrowingStream<Chunk, any Error> {
        AsyncThrowingStream {
            $0.finish(throwing: VectorStoreError.unimplemented("scan: implemented in Task 22"))
        }
    }

    public func summary() async throws -> EngineSummary {
        throw VectorStoreError.unimplemented("summary: implemented in Task 22")
    }
}
