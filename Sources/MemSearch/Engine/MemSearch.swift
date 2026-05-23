import Foundation

public struct MemSearch<V: VectorStore, E: EmbeddingProvider>: Sendable {
    public let paths: [URL]
    public let chunkingPolicy: ChunkingPolicy
    package let store: V
    package let embedder: E

    public init(paths: [URL], store: V, embedder: E, chunkingPolicy: ChunkingPolicy = .default) {
        self.paths = paths
        self.store = store
        self.embedder = embedder
        self.chunkingPolicy = chunkingPolicy
    }

    /// Read-only projection of the embedder's identity. Hosts in **sibling
    /// SwiftPM packages** can't see `package`-scoped `embedder`, so these
    /// projections give them the same diagnostic info (CLI `info`, SwiftUI
    /// dashboards) without widening `embedder` itself.
    public var modelName: String { embedder.modelName }
    public var dimension: Int { embedder.dimension }

    public func search(
        _ query: String,
        topK: Int = 10,
        filter: SourceFilter? = nil,
        rrfK: Int = 60
    ) async throws -> [SearchHit] {
        do {
            let qVec = try await embedder.embed([query])[0]
            let hq = HybridQuery(queryText: query, queryEmbedding: qVec, topK: topK, filter: filter, rrfK: rrfK)
            return try await store.hybridSearch(hq)
        } catch {
            throw MemSearchEngineErrors.lift(error)
        }
    }

    /// Read-only snapshot of engine state for hosts (CLI `info`, SwiftUI
    /// dashboards). Public so consumers in **sibling SwiftPM packages** —
    /// where `package`-scoped `store` and `embedder` aren't visible — can
    /// still introspect basic counts. Errors lift through `MemSearchError`
    /// the same way `search()` does.
    public func summary() async throws -> EngineSummary {
        do {
            return try await store.summary()
        } catch {
            throw MemSearchEngineErrors.lift(error)
        }
    }
}
