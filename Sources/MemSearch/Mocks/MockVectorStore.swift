import Foundation

package actor MockVectorStore: VectorStore {
    package nonisolated let dimension: Int
    private var records: [ChunkID: StoredChunk] = [:]
    /// In-order log of `upsert` / `delete` calls — useful for assertions.
    package private(set) var operationLog: [String] = []
    /// Optional canned ranking returned by `hybridSearch` when set. `private`
    /// so callers must use the documented `setCannedHits(_:)` setter — the var
    /// itself is never mutated from outside.
    private var cannedHits: [SearchHit]?

    package init(dimension: Int = 8) {
        self.dimension = dimension
    }

    package func upsert(_ items: [StoredChunk]) async throws -> Int {
        // Mirror SQLiteVectorStore's contract: dimension mismatches throw before
        // any state changes. Without this, engine tests against the mock would
        // miss dimension-validation regressions that the SQLite backend catches.
        for item in items where item.embedding.dimension != dimension {
            throw VectorStoreError.dimensionMismatch(
                expected: dimension, got: item.embedding.dimension
            )
        }
        for item in items { records[item.chunk.id] = item }
        operationLog.append("upsert(\(items.count))")
        return items.count
    }

    package func hybridSearch(_ q: HybridQuery) async throws -> [SearchHit] {
        if let canned = cannedHits { return canned }
        // Fallback: dense-cosine over in-memory records, no BM25.
        let qVec = q.queryEmbedding.values
        let scored: [SearchHit] = records.values.map { rec in
            let v = rec.embedding.values
            let dot = zip(qVec, v).map(*).reduce(0, +)
            let nq = sqrt(qVec.map { $0 * $0 }.reduce(0, +))
            let nv = sqrt(v.map { $0 * $0 }.reduce(0, +))
            let cos = (nq > 0 && nv > 0) ? dot / (nq * nv) : 0
            return SearchHit(chunk: rec.chunk, score: cos, denseScore: cos, bm25Score: nil)
        }
        return Array(scored.sorted(by: { $0.score > $1.score }).prefix(q.topK))
    }

    package nonisolated func scan(filter: SourceFilter?) -> AsyncThrowingStream<Chunk, any Error> {
        AsyncThrowingStream { continuation in
            // Capture the inner Task so `onTermination` can cancel it when the
            // consumer drops the stream — without this, the unstructured Task
            // leaks until completion.
            let task = Task {
                do {
                    // Observe cancellation *before* the actor hop — without
                    // this, a cancelled consumer still pays the full snapshot
                    // cost before the per-yield checkCancellation kicks in.
                    try Task.checkCancellation()
                    let snapshot = await self.snapshotChunks(filter: filter)
                    for c in snapshot {
                        try Task.checkCancellation()
                        continuation.yield(c)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func snapshotChunks(filter: SourceFilter?) -> [Chunk] {
        records.values.map(\.chunk).filter { c in
            guard let f = filter else { return true }
            return c.source.path.hasPrefix(f.prefix.path)
        }
    }

    package func indexedSources() async throws -> Set<URL> {
        Set(records.values.map(\.chunk.source))
    }

    package func chunkIDs(forSource source: URL) async throws -> Set<ChunkID> {
        Set(records.values.filter { $0.chunk.source == source }.map(\.chunk.id))
    }

    package func delete(ids: [ChunkID]) async throws -> Int {
        var n = 0
        for id in ids where records.removeValue(forKey: id) != nil { n += 1 }
        operationLog.append("delete(ids: \(n))")
        return n
    }

    package func delete(source: URL) async throws -> Int {
        let toRemove = records.filter { $0.value.chunk.source == source }.map(\.key)
        for id in toRemove { records.removeValue(forKey: id) }
        operationLog.append("delete(source: \(toRemove.count))")
        return toRemove.count
    }

    package func close() async { /* no-op */ }

    package func setCannedHits(_ hits: [SearchHit]?) { self.cannedHits = hits }

    /// Snapshot inside a single actor turn — both reads see the same
    /// `records` dict instance, so the pair is torn-free by construction.
    package func summary() async throws -> EngineSummary {
        let sources = Set(records.values.map(\.chunk.source))
        return EngineSummary(sourceCount: sources.count, chunkCount: records.count)
    }
}
