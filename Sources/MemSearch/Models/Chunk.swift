import Foundation

public struct Chunk: Sendable, Hashable {
    public let id: ChunkID
    public let source: URL
    public let heading: String
    public let headingLevel: Int
    public let startLine: Int
    public let endLine: Int
    public let content: String
    public let contentHash: String

    public init(
        id: ChunkID,
        source: URL,
        heading: String,
        headingLevel: Int,
        startLine: Int,
        endLine: Int,
        content: String,
        contentHash: String
    ) {
        self.id = id
        self.source = source
        self.heading = heading
        self.headingLevel = headingLevel
        self.startLine = startLine
        self.endLine = endLine
        self.content = content
        self.contentHash = contentHash
    }
}
