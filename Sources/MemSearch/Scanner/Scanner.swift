import Foundation

public enum Scanner {
    public static func scan(paths: [URL]) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for path in paths {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                if isMarkdown(path) { out.append(path) }
                continue
            }
            let opts: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
            guard let enumerator = fm.enumerator(at: path, includingPropertiesForKeys: nil, options: opts) else { continue }
            for case let url as URL in enumerator where isMarkdown(url) { out.append(url) }
        }
        return out.sorted { $0.path < $1.path }
    }

    private static func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown"].contains(url.pathExtension.lowercased())
    }
}
