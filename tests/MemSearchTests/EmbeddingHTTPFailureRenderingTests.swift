import Testing
@testable import MemSearch

@Suite("EmbeddingError httpFailure rendering")
struct EmbeddingHTTPFailureRenderingTests {

    @Test("renders status alone when body is nil")
    func statusOnly() {
        let err = EmbeddingError.httpFailure(statusCode: 500, body: nil)
        #expect(err.errorDescription == "Embedding HTTP 500")
    }

    @Test("renders status alone when body is empty")
    func statusEmptyBody() {
        let err = EmbeddingError.httpFailure(statusCode: 502, body: "")
        #expect(err.errorDescription == "Embedding HTTP 502")
    }

    @Test("strips control characters but preserves whitespace and ZWJ emoji glue")
    func sanitizeControlsAndKeepsZWJ() {
        let body = "ok\u{0007}line1\nline2\ttab\rcr\u{200D}joiner"
        let err = EmbeddingError.httpFailure(statusCode: 400, body: body)
        let rendered = err.errorDescription ?? ""
        // Diagnostic: report the raw rendered string for postmortem on failure.
        let expectedTail = "okline1\nline2\ttab\rcr\u{200D}joiner"
        #expect(rendered == "Embedding HTTP 400: \(expectedTail)",
                "rendered=\(rendered.unicodeScalars.map { String(format: "U+%04X", $0.value) })")
    }

    @Test("clamps body to 512 codepoints with single-codepoint ellipsis")
    func clampsLongBody() {
        let body = String(repeating: "a", count: 1024)
        let err = EmbeddingError.httpFailure(statusCode: 413, body: body)
        let rendered = err.errorDescription ?? ""
        #expect(rendered.hasSuffix("…"))
        let prefix = "Embedding HTTP 413: "
        #expect(rendered.hasPrefix(prefix))
        // 512 'a' scalars + the ellipsis (1 scalar)
        #expect(rendered.unicodeScalars.count == prefix.unicodeScalars.count + 513)
    }

    @Test("does NOT append ellipsis when filtered output is short, even if input was long")
    // iter-4 fix: truncation flag must be computed against the *filtered*
    // scalars, not the raw input. Previously a 5MB body of pure control
    // chars produced "" + "…" (misleading) because raw scalars exceeded 512.
    func ellipsisGatedByFilteredLength() {
        let body = String(repeating: "\u{0007}", count: 1024) // all Cc, all stripped
        let err = EmbeddingError.httpFailure(statusCode: 500, body: body)
        let rendered = err.errorDescription ?? ""
        #expect(rendered == "Embedding HTTP 500: ")
        #expect(!rendered.hasSuffix("…"))
    }

    @Test("redacts Bearer tokens that echo back from a misbehaving baseURL")
    func redactsBearerTokens() {
        let body = "Authorization: Bearer sk-proj-abc123XYZ_-.~+/="
        let err = EmbeddingError.httpFailure(statusCode: 502, body: body)
        let rendered = err.errorDescription ?? ""
        #expect(rendered.contains("Bearer [REDACTED]"))
        #expect(!rendered.contains("sk-proj-abc123"))
    }
}
