import Foundation

extension MemSearch {
    public func summarize<S: LLMSummarizer>(
        using summarizer: S,
        source: URL? = nil,
        promptTemplate: String? = nil,
        now: Date = Date()
    ) async throws -> CompactedSummary {
        throw MemSearchError.unimplemented("summarize: implemented in Phase 6")
    }

    public func appendSummary(_ summary: CompactedSummary, to outputDirectory: URL? = nil) async throws -> URL {
        throw MemSearchError.unimplemented("appendSummary: implemented in Phase 6")
    }

    public func watch(
        debounce: Duration = .milliseconds(250),
        bufferingPolicy: AsyncStream<IndexEvent>.Continuation.BufferingPolicy = .bufferingNewest(1024)
    ) throws -> AsyncStream<IndexEvent> {
        throw MemSearchError.unimplemented("watch: implemented in Phase 4")
    }
}
