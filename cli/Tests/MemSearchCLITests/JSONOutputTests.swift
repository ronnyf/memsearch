import Foundation
import Testing
@testable import MemSearchCLI

@Suite("Search JSON output")
struct JSONOutputTests {
    /// Spec lines 858–874 freeze these JSON keys for cross-language consumers
    /// (notably the Phase 1 Python parity check). Renaming any key is a
    /// breaking change to the CLI surface.
    @Test("schema keys stable across versions")
    func keys() throws {
        let hit = SearchOutput.Hit(
            chunkID: "abc",
            source: "/x.md",
            heading: "h",
            score: 0.9,
            denseScore: 0.8,
            bm25Score: 0.1,
            startLine: 1,
            endLine: 5,
            content: "c"
        )
        let data = try JSONEncoder.outputEncoder.encode(SearchOutput(hits: [hit]))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hits = json["hits"] as! [[String: Any]]
        #expect(hits[0]["chunk_id"] as? String == "abc")
        #expect(hits[0]["dense_score"] != nil)
        #expect(hits[0]["bm25_score"] != nil)
        #expect(hits[0]["start_line"] as? Int == 1)
        #expect(hits[0]["end_line"] as? Int == 5)
    }
}
