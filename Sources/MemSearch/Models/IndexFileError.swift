public enum IndexFileError: Error, Sendable {
    case embedding(EmbeddingError)
    case store(VectorStoreError)
    case scan(any Error & Sendable)
    case chunking(any Error & Sendable)
}
