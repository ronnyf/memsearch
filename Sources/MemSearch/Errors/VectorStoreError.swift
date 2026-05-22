public enum VectorStoreError: Error, Sendable {
    case connectionFailed(any Error & Sendable)
    case schemaIncompatible(reason: String)
    case dimensionMismatch(expected: Int, got: Int)
    case backendError(any Error & Sendable)
}
