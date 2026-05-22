import Foundation

public struct SourceFilter: Sendable {
    public let prefix: URL
    public init(prefix: URL) {
        self.prefix = prefix
    }
}
