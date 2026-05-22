import Foundation
import Testing
@testable import MemSearchEmbeddersHTTP
import MemSearch

/// `URLProtocol` subclasses are NSObject family and own internal mutable
/// state; the URL Loading System manages their lifecycle. Test-only mock
/// — `@unchecked Sendable` is the established Apple-platform pattern here
/// (cf. Apple's URLSession docs example). The Task 9 ban on escapes was
/// scoped to Sources/; tests have a documented exception.
final class CancelStubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }
    override func stopLoading() {}
}

@Suite("OpenAI cancellation translation")
struct OpenAICancellationTests {

    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [CancelStubProtocol.self]
        return URLSession(configuration: cfg)
    }

    @Test("URLError(.cancelled) on a cancelled Task surfaces as CancellationError")
    func cancelledTask() async throws {
        let session = makeSession()
        let embedder = OpenAIEmbedder(apiKey: "k", session: session)

        let outer = Task {
            try await embedder.embed(["hi"])
        }
        outer.cancel()

        await #expect(throws: CancellationError.self) { _ = try await outer.value }
    }

    @Test("URLError(.cancelled) on a NON-cancelled task surfaces as EmbeddingError.networkFailure")
    func nonTaskCancellation() async throws {
        let session = makeSession()
        let embedder = OpenAIEmbedder(apiKey: "k", session: session)

        // Run on a non-cancelled Task — `try Task.checkCancellation()` does NOT throw,
        // so the embedder re-throws as networkFailure.
        await #expect(throws: EmbeddingError.self) {
            _ = try await embedder.embed(["hi"])
        }
    }
}
