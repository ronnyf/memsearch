import Foundation

public struct IndexStats: Sendable {
    public let filesScanned: Int
    public let chunksAdded: Int
    public let chunksRemoved: Int
    public let failedFiles: [URL]

    public init(filesScanned: Int, chunksAdded: Int, chunksRemoved: Int, failedFiles: [URL]) {
        self.filesScanned = filesScanned
        self.chunksAdded = chunksAdded
        self.chunksRemoved = chunksRemoved
        self.failedFiles = failedFiles
    }
}
