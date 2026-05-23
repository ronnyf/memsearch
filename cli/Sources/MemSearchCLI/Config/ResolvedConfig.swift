import Foundation
import MemSearch

struct ResolvedConfig: Sendable {
    enum Backend: String, Codable, Sendable { case sqlite }
    enum Provider: String, Codable, Sendable { case openai }

    struct Store: Sendable {
        let backend: Backend
        let path: URL
        init(backend: Backend, path: URL) { self.backend = backend; self.path = path }
    }
    struct Embedder: Sendable {
        let provider: Provider
        let model: String
        let dimension: Int
        let apiKey: String?
        let baseURL: URL?
        init(provider: Provider, model: String, dimension: Int, apiKey: String?, baseURL: URL?) {
            self.provider = provider; self.model = model; self.dimension = dimension
            self.apiKey = apiKey; self.baseURL = baseURL
        }
    }

    let paths: [URL]
    let store: Store
    let embedder: Embedder
    let chunkingPolicy: ChunkingPolicy

    init(paths: [URL], store: Store, embedder: Embedder, chunkingPolicy: ChunkingPolicy) {
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
    /// Resolves env-var placeholders inside an optional string. Pass-through nil.
    private static func resolveOptional(_ s: String?, env: [String: String]) throws -> String? {
        guard let s else { return nil }
        return try EnvResolver.resolve(s, env: env)
    }

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

        let env = ProcessInfo.processInfo.environment

        // CLI flag override: --paths wins over the merged config.
        // Trim each comma-separated entry; drop empties.
        let pathStringsResolved: [String]
        if let cliPaths = common.paths {
            let raw = cliPaths.split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            pathStringsResolved = try raw.map { try EnvResolver.resolve($0, env: env) }
        } else if let mergedPaths = merged.paths {
            pathStringsResolved = try mergedPaths.map { try EnvResolver.resolve($0, env: env) }
        } else {
            pathStringsResolved = [(NSHomeDirectory() as NSString).appendingPathComponent("Documents/notes")]
        }
        let paths = pathStringsResolved.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

        let backend = merged.store?.backend ?? .sqlite
        let storePathRaw = try resolveOptional(merged.store?.path, env: env)
            ?? "~/Library/Application Support/MemSearch/memory.db"
        let storePath = URL(fileURLWithPath: (storePathRaw as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(
            at: storePath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let provider  = merged.embedder?.provider ?? .openai
        let model     = try resolveOptional(merged.embedder?.model, env: env) ?? "text-embedding-3-small"
        let dimension = merged.embedder?.dimension ?? 1536
        let apiKey    = try resolveOptional(merged.embedder?.apiKey, env: env)

        let baseURL: URL?
        if let baseURLString = try resolveOptional(merged.embedder?.baseURL, env: env) {
            guard let u = URL(string: baseURLString), u.scheme != nil else {
                throw MemSearchError.configurationInvalid("invalid base_url: \(baseURLString)")
            }
            // Restrict to https — the bearer token in `Authorization` would
            // be sent in cleartext over plain http. Allow http only when
            // pointing at localhost/127.0.0.1, which is a common local-dev
            // pattern (e.g. running an OpenAI-compatible proxy on
            // http://localhost:8080).
            let scheme = (u.scheme ?? "").lowercased()
            let host   = (u.host ?? "").lowercased()
            let isLocalhost = host == "localhost" || host == "127.0.0.1" || host == "::1"
            switch scheme {
            case "https":
                break
            case "http" where isLocalhost:
                break
            default:
                throw MemSearchError.configurationInvalid(
                    "base_url must be https (http only allowed for localhost): \(baseURLString)"
                )
            }
            baseURL = u
        } else {
            baseURL = nil
        }

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
