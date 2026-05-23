import Testing
@testable import MemSearch

@Suite("Embedding")
struct EmbeddingTests {

    @Test("init throws on dimension mismatch")
    func dimensionMismatch() {
        #expect(throws: EmbeddingError.self) {
            _ = try Embedding(values: [1, 2, 3], expectedDimension: 4)
        }
    }

    @Test("init succeeds when count matches")
    func dimensionMatches() throws {
        let e = try Embedding(values: [1, 2, 3, 4], expectedDimension: 4)
        #expect(e.dimension == 4)
        #expect(e.values == [1, 2, 3, 4])
    }
}
