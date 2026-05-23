package struct MockSummarizer: LLMSummarizer {
    package let canned: String
    package let injectedFailure: LLMError?

    package init(canned: String = "mock summary", injectedFailure: LLMError? = nil) {
        self.canned = canned
        self.injectedFailure = injectedFailure
    }

    package func summarize(prompt: String) async throws -> String {
        if let e = injectedFailure { throw e }
        return canned
    }
}
