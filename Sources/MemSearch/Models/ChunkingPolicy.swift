public struct ChunkingPolicy: Sendable {
    public let maxChunkSize: Int
    public let overlapLines: Int

    public init(maxChunkSize: Int, overlapLines: Int) {
        self.maxChunkSize = maxChunkSize
        self.overlapLines = overlapLines
    }

    public static let `default` = ChunkingPolicy(maxChunkSize: 1500, overlapLines: 2)
}
