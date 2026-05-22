import Foundation
import Testing
@testable import MemSearchCLI
import MemSearch

@Suite("IndexCommand error rendering")
struct IndexCommandRenderingTests {

    @Test("IndexFileError renders human-readable, not Swift type names")
    func indexFileErrorRendering() {
        let err = IndexFileError.embedding(.authenticationFailed)
        let rendered = (err as? LocalizedError)?.errorDescription ?? "\(err)"
        // Pre-fix output would be "embedding(MemSearch.EmbeddingError.authenticationFailed)".
        // Post-fix output uses the EmbeddingError.LocalizedError extension's message.
        #expect(rendered.contains("authentication"))
        #expect(!rendered.contains("MemSearch."))
        #expect(!rendered.hasPrefix("embedding("))
    }
}
