public struct HybridQuery: Sendable {
    public let queryText: String
    public let queryEmbedding: Embedding
    public let topK: Int
    public let filter: SourceFilter?
    public let rrfK: Int

    public init(
        queryText: String,
        queryEmbedding: Embedding,
        topK: Int,
        filter: SourceFilter?,
        rrfK: Int = 60
    ) {
        self.queryText = queryText
        self.queryEmbedding = queryEmbedding
        self.topK = topK
        self.filter = filter
        self.rrfK = rrfK
    }
}
