public struct StoredChunk: Sendable {
    public let chunk: Chunk
    public let embedding: Embedding
    public init(chunk: Chunk, embedding: Embedding) {
        self.chunk = chunk
        self.embedding = embedding
    }
}
