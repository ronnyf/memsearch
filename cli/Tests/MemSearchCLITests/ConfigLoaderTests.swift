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

    @Test("--paths trims whitespace and drops empty entries")
    func pathsTrimAndFilter() throws {
        let cfg = try ResolvedConfig.load(common: CommonOptions(
            config: "/nonexistent.json",
            paths: " /a , /b ,  , /c "
        ))
        #expect(cfg.paths == [
            URL(fileURLWithPath: "/a"),
            URL(fileURLWithPath: "/b"),
            URL(fileURLWithPath: "/c"),
        ])
    }

    @Test("invalid base_url throws configurationInvalid")
    func invalidBaseURL() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).json")
        try #"""
        {"embedder": {"base_url": "not a url"}}
        """#.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(throws: MemSearchError.self) {
            _ = try ResolvedConfig.load(common: CommonOptions(config: tmp.path, paths: nil))
        }
    }

    @Test("env-var resolution applies to all string fields")
    func envResolutionUniform() throws {
        setenv("MEMSEARCH_TEST_MODEL", "test-model-from-env", 1)
        setenv("MEMSEARCH_TEST_KEY", "sk-from-env", 1)
        defer {
            unsetenv("MEMSEARCH_TEST_MODEL")
            unsetenv("MEMSEARCH_TEST_KEY")
        }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).json")
        try #"""
        {
          "embedder": {
            "model": "${MEMSEARCH_TEST_MODEL}",
            "api_key": "${MEMSEARCH_TEST_KEY}"
          }
        }
        """#.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cfg = try ResolvedConfig.load(common: CommonOptions(config: tmp.path, paths: nil))
        #expect(cfg.embedder.model == "test-model-from-env")
        #expect(cfg.embedder.apiKey == "sk-from-env")
    }
}
