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
        case .httpFailure(let status, let body):
            if let body, !body.isEmpty { "Embedding HTTP \(status): \(sanitize(body))" }
            else { "Embedding HTTP \(status)" }
        }
    }
}

/// Defense-in-depth for `EmbeddingError.httpFailure(body:)`: third-party
/// HTTP-compatible endpoints (configurable `baseURL` on `OpenAIEmbedder`) may
/// echo headers including `Authorization`, return multi-MB HTML proxy pages,
/// or include control characters that corrupt terminal output. Strip non-
/// whitespace control / surrogate scalars, redact bearer tokens that echo
/// from a misbehaving proxy, and clamp body content at 512 codepoints (the
/// `…` suffix is appended on truncation, so the rendered length is 513).
/// Stays in the formatting layer so producers retain full forensic data.
private func sanitize(_ s: String) -> String {
    // Single-pass filter + clamp + truncation flag. Avoids the lazy-filter
    // ↔ UnicodeScalarView slice round-trip which silently dropped scalars
    // in iter-3. Bounded work: at most 513 input scalars are inspected
    // before `truncated` is set and the loop exits.
    var trimmed = ""
    trimmed.reserveCapacity(min(s.utf8.count, 512))
    var kept = 0
    var truncated = false
    for c in s.unicodeScalars {
        let isWhitespace = c == "\n" || c == "\t" || c == "\r"
        let isStripped = !isWhitespace && c.properties.generalCategory.isTerminalControl
        guard !isStripped else { continue }
        if kept >= 512 {
            truncated = true
            break
        }
        trimmed.unicodeScalars.append(c)
        kept += 1
    }
    let withSuffix = truncated ? trimmed + "…" : trimmed
    return redactBearerTokens(withSuffix)
}

/// Defense-in-depth: a hostile or buggy proxy at a custom `baseURL` could
/// echo back the `Authorization: Bearer <token>` header in its error body.
/// Strip the bearer value from any rendered string. Pattern matches
/// "Bearer " followed by URL-safe characters typical of API keys plus `=`
/// (base64 padding for JWT-style bearer tokens).
private func redactBearerTokens(_ s: String) -> String {
    s.replacingOccurrences(
        of: #"Bearer\s+[A-Za-z0-9\-_.~+/=]+"#,
        with: "Bearer [REDACTED]",
        options: .regularExpression
    )
}

private extension Unicode.GeneralCategory {
    /// Categories that meaningfully corrupt terminal output / log files.
    /// `.control` (Cc) is the obvious threat. `.surrogate` (Cs) cannot occur
    /// in a valid Swift `String` — UTF-8 decoding would have failed upstream
    /// — but include it for completeness. Cf (format, e.g. ZWJ) and Co
    /// (private use) are *intentionally excluded*: stripping ZWJ mangles
    /// emoji sequences (👨‍👩‍👧‍👦), and private-use scalars are user-content,
    /// not adversarial.
    var isTerminalControl: Bool {
        self == .control || self == .surrogate
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

extension IndexFileError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .embedding(let e):  e.errorDescription ?? "Embedding error: \(e)"
        case .store(let e):      e.errorDescription ?? "Vector store error: \(e)"
        case .scan(let e):       "File scan error: \(describe(e))"
        case .chunking(let e):   "Chunking error: \(describe(e))"
        }
    }
}
