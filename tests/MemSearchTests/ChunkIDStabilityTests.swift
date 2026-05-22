import Testing
@testable import MemSearch

@Suite("ChunkID stability")
struct ChunkIDStabilityTests {

    @Test("compute(source:start:end:contentHash:model:) matches Python reference")
    func matchesPython() {
        // Reference computed by:
        //   python3 -c "import hashlib; raw = b'markdown:test.md:1:10:abc1234567890def:openai-3-small'; print(hashlib.sha256(raw).hexdigest()[:16])"
        let id = ChunkID.compute(
            source: "test.md",
            startLine: 1,
            endLine: 10,
            contentHash: "abc1234567890def",
            model: "openai-3-small"
        )
        #expect(id.rawValue == "f39e14f8ee3b2a6f")   // pre-computed Python reference
    }

    @Test("contentHash uses sha256(content).prefix(16)")
    func contentHashShape() {
        let h = ChunkID.contentHash(for: "hello world")
        #expect(h.count == 16)
        #expect(h.allSatisfy { $0.isHexDigit })
        // Reference: python3 -c "import hashlib; print(hashlib.sha256(b'hello world').hexdigest()[:16])"
        #expect(h == "b94d27b9934d3e08")
    }
}
