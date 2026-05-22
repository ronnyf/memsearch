import Foundation

public struct CompactedSummary: Sendable {
    public let markdown: String
    public let dateStamp: Date
    public let chunkCount: Int

    public init(markdown: String, dateStamp: Date, chunkCount: Int) {
        self.markdown = markdown
        self.dateStamp = dateStamp
        self.chunkCount = chunkCount
    }

    /// "YYYY-MM-DD.md" derived from `dateStamp`. Uses Foundation's
    /// `Date.ISO8601FormatStyle` — locale-independent, UTC by default,
    /// no `DateFormatter`/`Locale`/`Calendar` setup required.
    public var proposedFilename: String {
        "\(dateStamp.formatted(.iso8601.year().month().day())).md"
    }
}
