import Foundation
import CryptoKit

public struct ChunkID: Hashable, Sendable {
    public let rawValue: String

    /// Mints a ChunkID. `package` so only the chunker (and tests) can call it.
    package init(_ rawValue: String) { self.rawValue = rawValue }
}

extension ChunkID {
    /// Composite ID matching `src/memsearch/chunker.py::compute_chunk_id`.
    /// `sha256("markdown:{source}:{start}:{end}:{contentHash}:{model}").hexdigest()[:16]`
    package static func compute(
        source: String,
        startLine: Int,
        endLine: Int,
        contentHash: String,
        model: String
    ) -> ChunkID {
        let raw = "markdown:\(source):\(startLine):\(endLine):\(contentHash):\(model)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return ChunkID(String(hex.prefix(16)))
    }

    /// `sha256(content).hexdigest()[:16]` — matches Python `Chunk.__post_init__`.
    package static func contentHash(for content: String) -> String {
        let digest = SHA256.hash(data: Data(content.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }
}
