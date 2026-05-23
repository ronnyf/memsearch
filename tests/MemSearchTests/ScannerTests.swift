import Foundation
import Testing
@testable import MemSearch

@Suite("Scanner")
struct ScannerTests {
    @Test("finds .md and .markdown; skips .txt")
    func basics() throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "a".write(to: tmp.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "b".write(to: tmp.appendingPathComponent("b.markdown"), atomically: true, encoding: .utf8)
        try "c".write(to: tmp.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        let out = Scanner.scan(paths: [tmp])
        #expect(out.count == 2)
    }

    @Test("skips symlinked .md files (path-traversal defense)")
    func skipsSymlinks() throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Real file inside the declared root.
        let regular = tmp.appendingPathComponent("regular.md")
        try "real".write(to: regular, atomically: true, encoding: .utf8)
        // Symlink to a real .md file outside the declared root.
        let outside = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outside) }
        let target = outside.appendingPathComponent("escape.md")
        try "leaked".write(to: target, atomically: true, encoding: .utf8)
        let link = tmp.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let out = Scanner.scan(paths: [tmp])
        #expect(out.map(\.lastPathComponent) == ["regular.md"])
    }

    private func makeTempDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scan-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
