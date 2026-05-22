import Foundation
import Testing
@testable import MemSearchEmbeddersHTTP
import MemSearch

/// `URLProtocol` subclasses are NSObject family and own internal mutable
/// state; the URL Loading System manages their lifecycle. Test-only mock
/// — `@unchecked Sendable` is the established Apple-platform pattern here.
final class MismatchedResponseProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // HTTP 200 with empty data array — caller asked for embeddings of N strings,
        // server returned 0. Postcondition `result.count == texts.count` should fail.
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        )!
        let body = Data(#"""{"data":[]}"""#.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("OpenAI contract")
struct OpenAIContractTests {

    @Test("postcondition: throws decodingFailed when response count != request count")
    func countMismatchPostcondition() async throws {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MismatchedResponseProtocol.self]
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }

        let embedder = OpenAIEmbedder(apiKey: "k", session: session)

        await #expect(throws: EmbeddingError.self) {
            _ = try await embedder.embed(["one", "two", "three"])
        }
    }
}
