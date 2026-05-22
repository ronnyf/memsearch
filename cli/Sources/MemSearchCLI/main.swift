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
}
