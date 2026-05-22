import Foundation
import Testing
@testable import MemSearchCLI
import MemSearch

@Suite("ConfigLoader + ResolvedConfig.load")
struct ConfigLoaderTests {

    @Test("defaults apply when no config file is present")
    func defaultsApplyWhenNoConfig() throws {
        let cfg = try ResolvedConfig.load(common: CommonOptions(config: "/nonexistent.json", paths: nil))
        #expect(cfg.embedder.provider == .openai)
        #expect(cfg.chunkingPolicy.maxChunkSize == 1500)
        #expect(cfg.chunkingPolicy.overlapLines == 2)
    }

    @Test("JSON overrides defaults; CLI --paths wins over JSON")
    func jsonOverridesDefaults() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).json")
        let body = #"""
        {
          "paths": ["/tmp/notes"],
          "embedder": {
            "model": "text-embedding-3-large",
            "dimension": 3072
          }
        }
        """#
        try body.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let cfg = try ResolvedConfig.load(common: CommonOptions(config: tmp.path, paths: nil))
        #expect(cfg.embedder.dimension == 3072)
        #expect(cfg.paths == [URL(fileURLWithPath: "/tmp/notes")])

        let cliOverride = try ResolvedConfig.load(common: CommonOptions(config: tmp.path, paths: "/cli/path"))
        #expect(cliOverride.paths == [URL(fileURLWithPath: "/cli/path")])
    }

    @Test("api_key / base_url JSON keys decode into apiKey / baseURL Swift names")
    func snakeCaseKeys() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).json")
        let body = #"""
        {"embedder": {"api_key": "sk-test", "base_url": "https://example.invalid/v1"}}
        """#
        try body.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cfg = try ResolvedConfig.load(common: CommonOptions(config: tmp.path, paths: nil))
        #expect(cfg.embedder.apiKey == "sk-test")
        #expect(cfg.embedder.baseURL?.absoluteString == "https://example.invalid/v1")
    }

    @Test("unsupported format throws MemSearchError.configurationInvalid")
    func unsupportedFormat() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).yaml")
        try "paths:\n  - /tmp\n".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(throws: MemSearchError.self) {
            _ = try ResolvedConfig.load(common: CommonOptions(config: tmp.path, paths: nil))
        }
    }
}
