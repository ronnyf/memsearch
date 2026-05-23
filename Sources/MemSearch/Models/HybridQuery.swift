public struct HybridQuery: Sendable {
    public let queryText: String
    public let queryEmbedding: Embedding
    public let topK: Int
    public let filter: SourceFilter?
    public let rrfK: Int
    /// Per-retriever candidate over-fetch multiplier. Higher values give
    /// RRF more room to fuse but cost memory + per-query work. Default 5
    /// matches the Python sibling. The store applies a floor (e.g. 50)
    /// so small `topK` queries still see enough candidates.
    public let candidateMultiplier: Int

    public init(
        queryText: String,
        queryEmbedding: Embedding,
        topK: Int,
        filter: SourceFilter?,
        rrfK: Int = 60,
        candidateMultiplier: Int = 5
    ) {
        self.queryText = queryText
        self.queryEmbedding = queryEmbedding
        self.topK = topK
        self.filter = filter
        self.rrfK = rrfK
        self.candidateMultiplier = candidateMultiplier
    }
}
