public enum VectorStoreError: Error, Sendable {
    case connectionFailed(any Error & Sendable)
    case schemaIncompatible(reason: String)
    case dimensionMismatch(expected: Int, got: Int)
    case backendError(any Error & Sendable)
    /// Surface declared in an earlier phase, implementation arrives in a later phase
    /// (or in a sibling task within Phase 1). String identifies the missing capability.
    case unimplemented(String)
}
