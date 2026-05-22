public enum EmbeddingError: Error, Sendable {
    case dimensionMismatch(expected: Int, got: Int)
}
