import Foundation
import Testing
@testable import MemSearch

@Suite("Chunker — golden fixture")
struct ChunkerGoldenTests {

    @Test("Swift output matches Python golden byte-for-byte")
    func goldenFixture() throws {
        let bundle = Bundle.module
        let inputURL = try #require(bundle.url(forResource: "chunker-input", withExtension: "md", subdirectory: "Fixtures"))
        let expectedURL = try #require(bundle.url(forResource: "chunker-expected", withExtension: "json", subdirectory: "Fixtures"))

        let text = try String(contentsOf: inputURL, encoding: .utf8)
        let actual = Chunker.chunk(
            text: text,
            source: URL(fileURLWithPath: "chunker-input.md"),
            policy: .default,
            embedderModelName: "test-model"
        )

        struct Expected: Decodable, Equatable {
            let id: String
            let source: String
            let heading: String
            let headingLevel: Int
            let startLine: Int
            let endLine: Int
            let contentHash: String
            let content: String
        }
        let expected = try JSONDecoder().decode([Expected].self, from: Data(contentsOf: expectedURL))

        #expect(actual.count == expected.count, "chunk count mismatch")
        for (a, e) in zip(actual, expected) {
            let where_ = "L\(e.startLine)–\(e.endLine)"
            #expect(a.id.rawValue == e.id, "ChunkID mismatch at \(where_)")
            #expect(a.heading == e.heading, "heading mismatch at \(where_)")
            #expect(a.headingLevel == e.headingLevel, "headingLevel mismatch at \(where_)")
            #expect(a.startLine == e.startLine, "startLine mismatch at \(where_)")
            #expect(a.endLine == e.endLine, "endLine mismatch at \(where_)")
            #expect(a.contentHash == e.contentHash, "contentHash mismatch at \(where_)")
            #expect(a.content == e.content, "content mismatch at \(where_)")
        }
    }
}
