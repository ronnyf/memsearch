import Foundation
import Testing
@testable import MemSearch

@Suite("Error lifting")
struct ErrorLiftingTests {
    @Test("EmbeddingError → .embedding preserves cause")
    func liftsEmbedding() {
        let cause = EmbeddingError.networkFailure(URLError(.notConnectedToInternet))
        guard case let lifted as MemSearchError = MemSearchEngineErrors.lift(cause),
              case .embedding(.networkFailure(let underlying as URLError)) = lifted else {
            Issue.record("wrong shape"); return
        }
        #expect(underlying.code == .notConnectedToInternet)
    }

    @Test("VectorStoreError → .store preserves reason")
    func liftsStore() {
        guard case let lifted as MemSearchError = MemSearchEngineErrors.lift(
            VectorStoreError.schemaIncompatible(reason: "v2")),
              case .store(.schemaIncompatible(let r)) = lifted else { Issue.record("wrong"); return }
        #expect(r == "v2")
    }

    @Test("CancellationError flows through unchanged")
    func cancellation() {
        let lifted = MemSearchEngineErrors.lift(CancellationError())
        #expect(lifted is CancellationError)
    }

    @Test("Unknown error returns unchanged — caller decides how to wrap")
    func unknown() {
        struct X: Error, Sendable {}
        let lifted = MemSearchEngineErrors.lift(X())
        #expect(lifted is X)
    }
}
