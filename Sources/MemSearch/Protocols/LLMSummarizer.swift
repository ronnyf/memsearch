public protocol LLMSummarizer: Sendable {
    func summarize(prompt: String) async throws -> String
}
