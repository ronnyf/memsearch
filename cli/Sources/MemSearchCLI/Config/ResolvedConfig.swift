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

/// On-disk shape of a memsearch config file. JSON in v1; the same `Codable`
/// struct round-trips through future YAML/TOML decoders without changing
/// any call site — only `ConfigLoader.load(at:)` adds a new dispatch case.
struct MemSearchConfigFile: Codable, Sendable {
    var paths: [String]?
    var store: Store?
    var embedder: Embedder?
    var chunking: Chunking?

    struct Store: Codable, Sendable {
        var backend: ResolvedConfig.Backend?
        var path: String?
    }

    struct Embedder: Codable, Sendable {
        var provider: ResolvedConfig.Provider?
        var model: String?
        var dimension: Int?
        var apiKey: String?
        var baseURL: String?

        enum CodingKeys: String, CodingKey {
            case provider, model, dimension
            case apiKey  = "api_key"
            case baseURL = "base_url"
        }
    }

    struct Chunking: Codable, Sendable {
        var maxChunkSize: Int?
        var overlapLines: Int?

        enum CodingKeys: String, CodingKey {
            case maxChunkSize = "max_chunk_size"
            case overlapLines = "overlap_lines"
        }
    }
}

extension ResolvedConfig {
    static func load(common: CommonOptions) throws -> ResolvedConfig {
        var merged = MemSearchConfigFile()
        let configFiles: [URL] = {
            if let p = common.config { return [URL(fileURLWithPath: p)] }
            return ConfigLoader.defaultPaths()
        }()
        for url in configFiles {
            if let layer = try ConfigLoader.load(at: url) {
                merged = merge(into: merged, layer: layer)
            }
        }

        // CLI flag override: --paths wins over the merged config.
        let pathStrings = common.paths?.split(separator: ",").map { String($0) }
            ?? merged.paths
            ?? [(NSHomeDirectory() as NSString).appendingPathComponent("Documents/notes")]
        let paths = pathStrings.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

        let backend = merged.store?.backend ?? .sqlite
        let storePathRaw = merged.store?.path
            ?? "~/Library/Application Support/MemSearch/memory.db"
        let storePath = URL(fileURLWithPath: (storePathRaw as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(
            at: storePath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let provider  = merged.embedder?.provider ?? .openai
        let model     = merged.embedder?.model ?? "text-embedding-3-small"
        let dimension = merged.embedder?.dimension ?? 1536
        let apiKey    = try merged.embedder?.apiKey.map { try EnvResolver.resolve($0) }
        let baseURL   = (merged.embedder?.baseURL).flatMap { URL(string: $0) }

        let chunking = ChunkingPolicy(
            maxChunkSize: merged.chunking?.maxChunkSize ?? 1500,
            overlapLines: merged.chunking?.overlapLines ?? 2
        )

        return ResolvedConfig(
            paths: paths,
            store: .init(backend: backend, path: storePath),
            embedder: .init(provider: provider, model: model, dimension: dimension, apiKey: apiKey, baseURL: baseURL),
            chunkingPolicy: chunking
        )
    }
}

private func merge(into base: MemSearchConfigFile, layer: MemSearchConfigFile) -> MemSearchConfigFile {
    var out = base
    if let p = layer.paths { out.paths = p }
    if let s = layer.store {
        var m = out.store ?? .init()
        if let v = s.backend { m.backend = v }
        if let v = s.path    { m.path = v }
        out.store = m
    }
    if let e = layer.embedder {
        var m = out.embedder ?? .init()
        if let v = e.provider  { m.provider = v }
        if let v = e.model     { m.model = v }
        if let v = e.dimension { m.dimension = v }
        if let v = e.apiKey    { m.apiKey = v }
        if let v = e.baseURL   { m.baseURL = v }
        out.embedder = m
    }
    if let c = layer.chunking {
        var m = out.chunking ?? .init()
        if let v = c.maxChunkSize { m.maxChunkSize = v }
        if let v = c.overlapLines { m.overlapLines = v }
        out.chunking = m
    }
    return out
}
