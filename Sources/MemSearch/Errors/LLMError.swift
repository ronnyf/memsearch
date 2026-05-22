public enum LLMError: Error, Sendable {
    case unavailable
    case authenticationFailed
    case rateLimited(retryAfter: Duration?)
    case contextWindowExceeded
    case unsupportedLocale
    case networkFailure(any Error & Sendable)
    case invalidResponse
    case modelFailure(any Error & Sendable)
    /// Surface for summarizers whose single-flight serialization was bypassed.
    /// Tests `#expect` zero occurrences. (Phase 6 implements summarizers.)
    case singleFlightViolation(any Error & Sendable)
}
