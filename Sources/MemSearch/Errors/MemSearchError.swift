import Foundation

public enum MemSearchError: Error, Sendable {
    case embedding(EmbeddingError)
    case store(VectorStoreError)
    case llm(LLMError)
    case scan(URL, any Error & Sendable)
    case chunking(URL, any Error & Sendable)
    case configurationInvalid(String)
    case noSummarizerConfigured
    /// Surface declared in an earlier phase, implementation arrives in a later phase.
    /// String identifies the missing capability and the phase that adds it.
    case unimplemented(String)
}
