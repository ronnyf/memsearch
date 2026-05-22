import ArgumentParser

@main
struct Memsearch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "memsearch",
        abstract: "Semantic memory search for Markdown notes",
        subcommands: [IndexCommand.self, SearchCommand.self, InfoCommand.self]
    )
}

struct CommonOptions: ParsableArguments {
    @Option(help: "Path to a config file (JSON; .json)") var config: String?
    @Option(help: "Override paths (comma-separated)") var paths: String?

    /// ArgumentParser populates the @Option-wrapped fields via Decodable, so the
    /// synthesized memberwise init takes `Option<String?>` rather than `String?`.
    /// This convenience init exists for programmatic use (tests, in-process API)
    /// where callers want plain `String?` values.
    init(config: String? = nil, paths: String? = nil) {
        self.config = config
        self.paths = paths
    }

    // ArgumentParser still needs the zero-arg default-init that property wrappers provide.
    init() {}
}
