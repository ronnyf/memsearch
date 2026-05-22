import Testing
@testable import MemSearch

@Suite("RRF.fuse")
struct RRFTests {
    @Test("single retriever — top item normalized to 1.0")
    func singleRetriever() {
        let fused = RRF.fuse([[ChunkID("a"), ChunkID("b"), ChunkID("c")]], k: 60, topK: 3)
        #expect(fused.count == 3)
        #expect(fused[0].0 == ChunkID("a"))
        #expect(abs(fused[0].1 - 1.0) < 1e-6)
    }

    @Test("two retrievers — fused score is sum of reciprocal ranks")
    func twoRetrievers() {
        let fused = RRF.fuse([[ChunkID("a"), ChunkID("b")], [ChunkID("b"), ChunkID("a")]], k: 60, topK: 2)
        #expect(Set(fused.map(\.0)) == [ChunkID("a"), ChunkID("b")])
        // a, b each rank #1 in one retriever and #2 in the other.
        // Raw = 1/61 + 1/62 ≈ 0.03252; max = 2/61 ≈ 0.03279; norm ≈ 0.9919.
        #expect(abs(fused[0].1 - 1.0) < 1e-2)
    }

    @Test("topK bounds the output")
    func topKBound() {
        let fused = RRF.fuse([[ChunkID("a"), ChunkID("b"), ChunkID("c")]], k: 60, topK: 1)
        #expect(fused.count == 1)
    }
}
