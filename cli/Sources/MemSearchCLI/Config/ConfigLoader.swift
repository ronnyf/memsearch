import Foundation
import MemSearch

/// Loads a `MemSearchConfigFile` from disk. v1 supports JSON only; YAML / TOML
/// add-on cases are reserved by the file-extension dispatch below.
enum ConfigLoader {
    static func load(at url: URL) throws -> MemSearchConfigFile? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        switch url.pathExtension.lowercased() {
        case "json":
            return try JSONDecoder().decode(MemSearchConfigFile.self, from: data)
        case "yml", "yaml", "toml":
            throw MemSearchError.configurationInvalid(
                "config format '\(url.pathExtension)' not supported in v1; only .json is supported. " +
                "(YAML/TOML loaders plug in at this dispatch in a later phase.)"
            )
        default:
            throw MemSearchError.configurationInvalid(
                "unknown config file extension: '\(url.pathExtension)'. v1 supports .json only."
            )
        }
    }

    /// Default config locations searched when `--config` is not given:
    /// 1. `~/.config/memsearch/config.json`
    /// 2. `./.memsearch.json`
    static func defaultPaths() -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let cwd  = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return [
            home.appendingPathComponent(".config/memsearch/config.json"),
            cwd.appendingPathComponent(".memsearch.json"),
        ]
    }
}
