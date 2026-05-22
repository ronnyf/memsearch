import ArgumentParser
struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "search")
    func run() async throws { fatalError("populated in Task 27") }
}
