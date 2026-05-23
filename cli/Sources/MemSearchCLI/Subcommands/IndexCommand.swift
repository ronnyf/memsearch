import ArgumentParser
import Foundation
import MemSearch

struct IndexCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "index", abstract: "Index Markdown files")
    @OptionGroup var common: CommonOptions
    @Flag(name: .long, help: "Re-index even when chunks are unchanged")
    var force: Bool = false

    func run() async throws {
        let cfg = try ResolvedConfig.load(common: common)
        try await BackendDispatch.run(cfg) { mem in
            for try await event in mem.indexStream(force: force) {
                let line: String
                switch event {
                case .indexed(let url, let added, let removed):
                    line = "indexed \(url.lastPathComponent) (+\(added) -\(removed))\n"
                case .removed(let url, let n):
                    line = "removed \(url.lastPathComponent) (-\(n))\n"
                case .failed(let url, let err):
                    let desc = (err as? LocalizedError)?.errorDescription ?? "\(err)"
                    FileHandle.standardError.write(Data("failed \(url.lastPathComponent): \(desc)\n".utf8))
                    continue
                }
                FileHandle.standardOutput.write(Data(line.utf8))
            }
        }
    }
}
