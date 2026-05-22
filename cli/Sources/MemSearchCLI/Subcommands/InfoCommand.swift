import ArgumentParser
struct InfoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "info")
    func run() async throws { fatalError("populated in Task 28") }
}
