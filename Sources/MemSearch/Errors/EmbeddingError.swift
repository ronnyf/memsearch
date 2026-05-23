public enum EmbeddingError: Error, Sendable {
    case authenticationFailed
    case rateLimited(retryAfter: Duration?)
    case dimensionMismatch(expected: Int, got: Int)
    case modelNotFound(String)
    case networkFailure(any Error & Sendable)
    case decodingFailed(any Error & Sendable)
    /// HTTP status outside 200..<300 that isn't 401 or 429. Body is the raw
    /// response payload (often a structured error from the provider) — useful
    /// for "model not found" / "payload too large" / 5xx debugging where the
    /// status alone doesn't disambiguate transient vs. permanent.
    case httpFailure(statusCode: Int, body: String?)
}
