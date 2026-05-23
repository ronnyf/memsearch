import ArgumentParser
import Foundation
import MemSearch

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "search", abstract: "Hybrid search over the index")
    @OptionGroup var common: CommonOptions
    @Argument var query: String
    @Option(name: .shortAndLong) var k: Int = 10
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let cfg = try ResolvedConfig.load(common: common)
        try await BackendDispatch.run(cfg) { mem in
            let hits = try await mem.search(query, topK: k)
            if json {
                let envelope = SearchOutput(hits: hits.map(SearchOutput.Hit.init))
                let data = try JSONEncoder.outputEncoder.encode(envelope)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                for hit in hits {
                    // Use POSIX locale for `%.3f` so non-US locales (e.g. fr_FR)
                    // don't emit comma decimal separators that break shell pipelines.
                    let line = String(
                        format: "%.3f  %@:%d-%d  %@\n",
                        locale: Locale(identifier: "en_US_POSIX"),
                        hit.score,
                        hit.chunk.source.lastPathComponent,
                        hit.chunk.startLine,
                        hit.chunk.endLine,
                        hit.chunk.heading
                    )
                    FileHandle.standardOutput.write(Data(line.utf8))
                }
            }
        }
    }
}

struct SearchOutput: Codable, Sendable {
    let hits: [Hit]
    struct Hit: Codable, Sendable {
        let chunkID: String
        let source: String
        let heading: String
        let score: Float
        let denseScore: Float?
        let bm25Score: Float?
        let startLine: Int
        let endLine: Int
        let content: String

        enum CodingKeys: String, CodingKey {
            case chunkID = "chunk_id"
            case source, heading, score
            case denseScore = "dense_score"
            case bm25Score = "bm25_score"
            case startLine = "start_line"
            case endLine = "end_line"
            case content
        }
    }
}

extension SearchOutput.Hit {
    /// Convenience init from an engine `SearchHit`. Lives in an extension so the
    /// synthesized memberwise init remains available for tests.
    init(_ h: SearchHit) {
        self.init(
            chunkID: h.chunk.id.rawValue,
            source: h.chunk.source.path,
            heading: h.chunk.heading,
            score: h.score,
            denseScore: h.denseScore,
            bm25Score: h.bm25Score,
            startLine: h.chunk.startLine,
            endLine: h.chunk.endLine,
            content: h.chunk.content
        )
    }
}

extension JSONEncoder {
    static let outputEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}
