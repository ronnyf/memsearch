import Foundation

struct OpenAIEmbeddingRequest: Codable, Sendable {
    let input: [String]
    let model: String
}

struct OpenAIEmbeddingResponse: Codable, Sendable {
    struct Datum: Codable, Sendable { let embedding: [Float]; let index: Int }
    let data: [Datum]
}
