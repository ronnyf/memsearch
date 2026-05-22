// cli/Sources/memsearch/main.swift
import ArgumentParser

@main
struct Memsearch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "memsearch",
        abstract: "Semantic memory search",
        subcommands: []  // Tasks 25–29 register IndexCommand / SearchCommand / InfoCommand
    )
}
