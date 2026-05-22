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
