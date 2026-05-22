import Foundation
import Testing
@testable import MemSearch

@Suite("Chunker — edge cases")
struct ChunkerTests {

    @Test("empty input → no chunks")
    func empty() {
        #expect(Chunker.chunk(text: "", source: URL(fileURLWithPath: "x.md"), embedderModelName: "m").isEmpty)
    }

    @Test("preamble before first heading is its own chunk")
    func preamble() {
        let text = "intro line\n\n# H1\nbody"
        let out = Chunker.chunk(text: text, source: URL(fileURLWithPath: "x.md"), embedderModelName: "m")
        #expect(out.count == 2)
        #expect(out[0].heading == "")
        #expect(out[0].headingLevel == 0)
        #expect(out[1].heading == "H1")
        #expect(out[1].headingLevel == 1)
    }

    @Test("heading-only sections (no body) are dropped")
    func headingOnly() {
        let text = "# H1\n## H2\n## H3\nbody"
        let out = Chunker.chunk(text: text, source: URL(fileURLWithPath: "x.md"), embedderModelName: "m")
        #expect(out.count == 1)
        #expect(out[0].heading == "H3")
    }

    @Test("contentHash is sha256(content).prefix(16)")
    func contentHashShape() {
        let text = "# H1\nhello"
        let out = Chunker.chunk(text: text, source: URL(fileURLWithPath: "x.md"), embedderModelName: "m")
        #expect(out[0].contentHash == ChunkID.contentHash(for: out[0].content))
    }

    /// Anchors the `_split_long_text` (intra-line) path so the sentence-boundary
    /// regex stays exercised. Reference computed via `chunker.py` with
    /// `max_chunk_size=80` for the same input — see test body for raw values.
    @Test("intra-line split prefers sentence boundary")
    func intraLineSentenceSplit() {
        let sentences = (1...5).map { "This is sentence \($0)." }.joined(separator: " ")
        let text = "# Heading\n\(sentences)"
        let policy = ChunkingPolicy(maxChunkSize: 80, overlapLines: 2)
        let out = Chunker.chunk(
            text: text,
            source: URL(fileURLWithPath: "long.md"),
            policy: policy,
            embedderModelName: "m"
        )
        // Python reference (chunker.py, max_chunk_size=80) produces:
        //   [0] L1-1: "# Heading"
        //   [1] L1-2: "# Heading\nThis is sentence 1. This is sentence 2. This is sentence 3."
        //   [2] L1-2: "This is sentence 4. This is sentence 5."
        #expect(out.count == 3)
        #expect(out[0].content == "# Heading")
        #expect(out[1].content == "# Heading\nThis is sentence 1. This is sentence 2. This is sentence 3.")
        #expect(out[2].content == "This is sentence 4. This is sentence 5.")
    }
}
