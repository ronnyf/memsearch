import Foundation
import MemSearch

public struct ResolvedConfig: Sendable {
    public enum Backend: String, Codable, Sendable { case sqlite }
    public enum Provider: String, Codable, Sendable { case openai }

    public struct Store: Sendable {
        public let backend: Backend
        public let path: URL
        public init(backend: Backend, path: URL) { self.backend = backend; self.path = path }
    }
    public struct Embedder: Sendable {
        public let provider: Provider
        public let model: String
        public let dimension: Int
        public let apiKey: String?
        public let baseURL: URL?
        public init(provider: Provider, model: String, dimension: Int, apiKey: String?, baseURL: URL?) {
            self.provider = provider; self.model = model; self.dimension = dimension
            self.apiKey = apiKey; self.baseURL = baseURL
        }
    }

    public let paths: [URL]
    public let store: Store
    public let embedder: Embedder
    public let chunkingPolicy: ChunkingPolicy

    public init(paths: [URL], store: Store, embedder: Embedder, chunkingPolicy: ChunkingPolicy) {
        self.paths = paths; self.store = store; self.embedder = embedder; self.chunkingPolicy = chunkingPolicy
    }
}

extension ResolvedConfig {
    /// Phase 1 placeholder. Task 29 replaces this with the layered JSON config loader.
    /// For now: hardcoded sane defaults; honors --paths and rejects --config.
    static func load(common: CommonOptions) throws -> ResolvedConfig {
        if common.config != nil {
            throw MemSearchError.configurationInvalid(
                "Config file loading lands in Task 29; only env-var + --paths are supported in this Phase 1 milestone"
            )
        }
        let pathStrings: [String]
        if let p = common.paths {
            pathStrings = p.split(separator: ",").map { String($0) }
        } else {
            pathStrings = []
        }
        let paths = pathStrings.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

        let storeDir = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/MemSearch")
        try FileManager.default.createDirectory(
            atPath: storeDir, withIntermediateDirectories: true)
        let storePath = URL(fileURLWithPath: storeDir).appendingPathComponent("memory.db")

        let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]

        return ResolvedConfig(
            paths: paths,
            store: .init(backend: .sqlite, path: storePath),
            embedder: .init(
                provider: .openai,
                model: "text-embedding-3-small",
                dimension: 1536,
                apiKey: apiKey,
                baseURL: nil
            ),
            chunkingPolicy: .default
        )
    }
}
