import Foundation
import MemSearch

/// Translates a caught `URLError` from a `URLSession.data(for:)` await.
///
/// Cooperative cancellation path: if the surrounding `Task` is cancelled,
/// `try Task.checkCancellation()` throws `CancellationError` — which is what
/// hosts pattern-match. Spec line 949 mandates that `Swift.CancellationError`
/// flows through unchanged.
///
/// Non-task-driven URL cancel (rare; e.g. URLSessionConfiguration
/// `timeoutIntervalForRequest`): returns the URLError as
/// `EmbeddingError.networkFailure(URLError)` so hosts can retry.
func translateURLError(_ urlError: URLError) throws -> Never {
    if urlError.code == .cancelled {
        try Task.checkCancellation()   // throws CancellationError if Task cancelled
        throw EmbeddingError.networkFailure(urlError)
    }
    throw EmbeddingError.networkFailure(urlError)
}
