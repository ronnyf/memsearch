import Foundation
import MemSearch

public final class OpenAIEmbedder: EmbeddingProvider, Sendable {
    public nonisolated let modelName: String
    public nonisolated let dimension: Int

    let apiKey: String
    let baseURL: URL
    let session: URLSession

    public init(
        apiKey: String,
        model: String = "text-embedding-3-small",
        dimension: Int = 1536,
        baseURL: URL = URL(string: "https://api.openai.com/v1")!,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.modelName = model
        self.dimension = dimension
        self.baseURL = baseURL
        self.session = session
    }

    public func embed(_ texts: [String]) async throws -> [Embedding] {
        guard !texts.isEmpty else { return [] }

        let url = baseURL.appendingPathComponent("embeddings")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(OpenAIEmbeddingRequest(input: texts, model: modelName))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let urlError as URLError {
            try translateURLError(urlError)   // returns Never; throws CancellationError or EmbeddingError.networkFailure
        }

        guard let http = response as? HTTPURLResponse else {
            throw EmbeddingError.networkFailure(URLError(.badServerResponse))
        }
        switch http.statusCode {
        case 200..<300: break
        case 401:
            throw EmbeddingError.authenticationFailed
        case 429:
            let retry: Duration? = http.value(forHTTPHeaderField: "Retry-After")
                .flatMap(Double.init).map(Duration.seconds)
            throw EmbeddingError.rateLimited(retryAfter: retry)
        default:
            throw EmbeddingError.networkFailure(URLError(.badServerResponse))
        }

        let decoded: OpenAIEmbeddingResponse
        do {
            decoded = try JSONDecoder().decode(OpenAIEmbeddingResponse.self, from: data)
        } catch {
            throw EmbeddingError.decodingFailed(error)
        }

        let sorted = decoded.data.sorted { $0.index < $1.index }
        guard sorted.count == texts.count else {
            throw EmbeddingError.decodingFailed(URLError(.badServerResponse))
        }
        return try sorted.map { try Embedding(values: $0.embedding, expectedDimension: dimension) }
    }
}
