public struct SearchHit: Sendable, Hashable {
    public let chunk: Chunk
    public let score: Float
    public let denseScore: Float?
    public let bm25Score: Float?

    public init(chunk: Chunk, score: Float, denseScore: Float?, bm25Score: Float?) {
        self.chunk = chunk
        self.score = score
        self.denseScore = denseScore
        self.bm25Score = bm25Score
    }
}
