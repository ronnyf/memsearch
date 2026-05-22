import Foundation

/// Renders any `Error` for end-user display: prefer `LocalizedError.errorDescription`,
/// then `NSError.localizedDescription`, finally fall back to `String(describing:)`.
/// `some Error` opens the existential at the call site (SE-0352) — no boxed
/// `any Error` argument, no extra existential dispatch.
private func describe(_ error: some Error) -> String {
    if let localized = (error as? LocalizedError)?.errorDescription { return localized }
    return (error as NSError).localizedDescription
}

private func describe(_ retryAfter: Duration?) -> String {
    guard let d = retryAfter else { return "soon" }
    return "\(d)"
}

extension MemSearchError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .embedding(let e):              "Embedding error: \(e.errorDescription ?? "\(e)")"
        case .store(let e):                  "Vector store error: \(e.errorDescription ?? "\(e)")"
        case .llm(let e):                    "LLM error: \(e.errorDescription ?? "\(e)")"
        case .scan(let url, let e):          "Failed to read \(url.path): \(describe(e))"
        case .chunking(let url, let e):      "Failed to chunk \(url.path): \(describe(e))"
        case .configurationInvalid(let m):   "Configuration invalid: \(m)"
        case .noSummarizerConfigured:        "No summarizer configured"
        case .unimplemented(let m):          "Not implemented: \(m)"
        }
    }
}

extension EmbeddingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .authenticationFailed:            "Embedding authentication failed"
        case .rateLimited(let retryAfter):     "Embedding rate-limited (retry after \(describe(retryAfter)))"
        case .dimensionMismatch(let e, let g): "Embedding dimension mismatch (expected \(e), got \(g))"
        case .modelNotFound(let name):         "Embedding model not found: \(name)"
        case .networkFailure(let e):           "Embedding network failure: \(describe(e))"
        case .decodingFailed(let e):           "Embedding response decoding failed: \(describe(e))"
        }
    }
}

extension VectorStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let e):            "Vector store connection failed: \(describe(e))"
        case .schemaIncompatible(let r):          "Vector store schema incompatible: \(r)"
        case .dimensionMismatch(let exp, let g):  "Vector store dimension mismatch (expected \(exp), got \(g))"
        case .backendError(let e):                "Vector store backend error: \(describe(e))"
        case .unimplemented(let m):               "Vector store not implemented: \(m)"
        }
    }
}

extension LLMError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable:                  "LLM unavailable"
        case .authenticationFailed:         "LLM authentication failed"
        case .rateLimited(let retryAfter):  "LLM rate-limited (retry after \(describe(retryAfter)))"
        case .contextWindowExceeded:        "LLM context window exceeded"
        case .unsupportedLocale:            "LLM locale unsupported"
        case .networkFailure(let e):        "LLM network failure: \(describe(e))"
        case .invalidResponse:              "LLM invalid response"
        case .modelFailure(let e):          "LLM model failure: \(describe(e))"
        case .singleFlightViolation(let e): "LLM single-flight violation: \(describe(e))"
        }
    }
}
