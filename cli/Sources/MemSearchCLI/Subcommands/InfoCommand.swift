import ArgumentParser
import Foundation
import MemSearch

struct InfoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "info", abstract: "Show store stats")
    @OptionGroup var common: CommonOptions

    func run() async throws {
        let cfg = try ResolvedConfig.load(common: common)
        try await BackendDispatch.run(cfg) { mem in
            // `mem.summary()` is the public engine snapshot — `mem.store` is
            // `package`-scoped and not visible from this sibling SPM package.
            let snap = try await mem.summary()
            let summary = """
                Store path: \(cfg.store.path.path)
                Backend:    \(cfg.store.backend.rawValue)
                Embedder:   \(cfg.embedder.provider.rawValue) (\(cfg.embedder.model), dim \(cfg.embedder.dimension))
                Sources:    \(snap.sourceCount)
                Chunks:     \(snap.chunkCount)

                """
            FileHandle.standardOutput.write(Data(summary.utf8))
        }
    }
}
