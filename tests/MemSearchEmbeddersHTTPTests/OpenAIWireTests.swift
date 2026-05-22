import Foundation
import Testing
@testable import MemSearchEmbeddersHTTP

@Suite("OpenAI wire format")
struct OpenAIWireTests {

    @Test("request encodes input + model")
    func encode() throws {
        let req = OpenAIEmbeddingRequest(input: ["hi", "there"], model: "text-embedding-3-small")
        let json = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(req)) as! [String: Any]
        #expect(json["model"] as? String == "text-embedding-3-small")
        #expect((json["input"] as? [String])?.count == 2)
    }

    @Test("response decodes data array preserving index order")
    func decode() throws {
        let body = #"""
        {"data":[{"index":1,"embedding":[0.3,0.4]},{"index":0,"embedding":[0.1,0.2]}]}
        """#
        let resp = try JSONDecoder().decode(OpenAIEmbeddingResponse.self, from: Data(body.utf8))
        #expect(resp.data.count == 2)
        let sorted = resp.data.sorted { $0.index < $1.index }
        #expect(sorted[0].embedding == [0.1, 0.2])
        #expect(sorted[1].embedding == [0.3, 0.4])
    }
}
