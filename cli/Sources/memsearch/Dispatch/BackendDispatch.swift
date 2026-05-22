import Foundation
import MemSearch
import MemSearchSQLite
import MemSearchEmbeddersHTTP

enum BackendDispatch {

    /// Phase 1 supports exactly 1 dispatch case: sqlite × openai.
    /// Phase 2+ extends to 4 cases (Core ML), Phase 3 to 8 (SwiftData × {openai, coreml}),
    /// Phase 5 to 8 (4 embedders × 2 stores), Phase 6 to 16 (× 2 summarizers).
    /// At Phase 6 the cartesian product warrants macro generation.
    static func run<R: Sendable>(
        _ cfg: ResolvedConfig,
        _ body: @Sendable (MemSearch<SQLiteVectorStore, OpenAIEmbedder>) async throws -> R
    ) async throws -> R {
        guard cfg.store.backend == .sqlite, cfg.embedder.provider == .openai else {
            throw MemSearchError.configurationInvalid("Phase 1 supports only sqlite + openai")
        }
        let store = try await SQLiteVectorStore(url: cfg.store.path, dimension: cfg.embedder.dimension)
        let embedder = OpenAIEmbedder(
            apiKey: cfg.embedder.apiKey ?? "",
            model: cfg.embedder.model,
            dimension: cfg.embedder.dimension,
            baseURL: cfg.embedder.baseURL ?? URL(string: "https://api.openai.com/v1")!
        )
        let mem = MemSearch(paths: cfg.paths, store: store, embedder: embedder, chunkingPolicy: cfg.chunkingPolicy)
        return try await body(mem)
    }
}
