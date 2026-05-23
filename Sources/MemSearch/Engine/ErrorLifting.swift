import Foundation

package enum MemSearchEngineErrors {
    /// Maps known narrow errors to `MemSearchError`. `Swift.CancellationError`
    /// flows through unchanged. Unknown errors are returned as-is — the catch
    /// site decides whether to wrap further (typically by re-throwing inside
    /// a typed-catch context, or by wrapping in `UnknownIndexError`).
    ///
    /// Uses `some Error` opaque parameter (SE-0352) so call sites with a
    /// concrete typed error don't pay an existential boxing round-trip.
    /// At call sites with `any Error` (e.g. an untyped `catch`), Swift
    /// implicitly opens the existential.
    package static func lift(_ error: some Error) -> any Error {
        if error is CancellationError         { return error }
        if let e = error as? MemSearchError   { return e }
        if let e = error as? EmbeddingError   { return MemSearchError.embedding(e) }
        if let e = error as? VectorStoreError { return MemSearchError.store(e) }
        if let e = error as? LLMError         { return MemSearchError.llm(e) }
        return error
    }
}
