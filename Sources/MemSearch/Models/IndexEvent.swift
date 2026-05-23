import Foundation

public enum IndexEvent: Sendable {
    case indexed(URL, added: Int, removed: Int)
    case removed(URL, chunkCount: Int)
    case failed(URL, IndexFileError)
}
