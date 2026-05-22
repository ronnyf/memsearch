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

    private func makeTempDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scan-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
