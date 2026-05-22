import Foundation

public protocol VectorStore: Sendable {
    nonisolated var dimension: Int { get }

    func upsert(_ records: [StoredChunk]) async throws -> Int
    func hybridSearch(_ query: HybridQuery) async throws -> [SearchHit]

    /// Stream every chunk matching the optional filter. The stream's `Failure`
    /// is `any Error` (Swift 6.0 stdlib limitation; narrow when 6.1 is the floor).
    func scan(filter: SourceFilter?) -> AsyncThrowingStream<Chunk, any Error>

    func indexedSources() async throws -> Set<URL>
    func chunkIDs(forSource: URL) async throws -> Set<ChunkID>
    func delete(ids: [ChunkID]) async throws -> Int
    func delete(source: URL) async throws -> Int

    /// Snapshot-consistent counts in a single backend round-trip — must be
    /// computed inside one read transaction so concurrent writers cannot
    /// produce torn `(sources, chunks)` pairs. SQLite implements this as
    /// `SELECT COUNT(DISTINCT source), COUNT(*) FROM chunks_meta` inside
    /// `pool.read`. Loop-2 review surfaced that an N+1 engine-level loop
    /// over `indexedSources()` + `chunkIDs(forSource:)` raced concurrent
    /// `indexStream` calls; this protocol method removes the gap.
    func summary() async throws -> EngineSummary

    func close() async
}
