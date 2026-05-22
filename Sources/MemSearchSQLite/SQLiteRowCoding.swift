import Foundation
import GRDB
import MemSearch

extension Chunk {
    /// Decodes a `chunks_meta` row into a `Chunk`.
    ///
    /// Centralised here so Tasks 21 / 22 (hybrid search, scan) can reuse the
    /// same column ordering — drift between SQL projections and decoder is
    /// the single biggest hazard in raw-row pipelines.
    static func make(fromMetaRow row: Row) -> Chunk {
        let chunkID: String = row["chunk_id"]
        let source: String = row["source"]
        let heading: String = row["heading"]
        let headingLevel: Int = row["heading_level"]
        let startLine: Int = row["start_line"]
        let endLine: Int = row["end_line"]
        let content: String = row["content"]
        let contentHash: String = row["content_hash"]
        return Chunk(
            id: ChunkID(chunkID),
            source: URL(fileURLWithPath: source),
            heading: heading,
            headingLevel: headingLevel,
            startLine: startLine,
            endLine: endLine,
            content: content,
            contentHash: contentHash
        )
    }
}

/// Encodes a Float vector as a raw little-endian Data blob — sqlite-vec's
/// expected `vec0` column wire format. `withUnsafeBufferPointer` materialises
/// the contiguous storage Float arrays guarantee; this avoids a per-element
/// copy and matches the format used by `SchemaMigrationTests.vec0RoundTrip`.
func embeddingBlob(_ values: [Float]) -> Data {
    values.withUnsafeBufferPointer { Data(buffer: $0) }
}
