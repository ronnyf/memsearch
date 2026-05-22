public protocol EmbeddingProvider: Sendable {
    nonisolated var modelName: String { get }
    nonisolated var dimension: Int { get }

    /// - Postcondition on success: `result.count == texts.count` and
    ///   `result[i]` corresponds to `texts[i]`.
    /// - Throws: on first failure; partial success is not exposed.
    func embed(_ texts: [String]) async throws -> [Embedding]
}
