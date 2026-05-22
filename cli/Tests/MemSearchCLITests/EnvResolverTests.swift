import Testing
@testable import MemSearchCLI
import MemSearch

@Suite("EnvResolver")
struct EnvResolverTests {
    @Test func setVar() throws { #expect(try EnvResolver.resolve("${X}", env: ["X": "y"]) == "y") }
    @Test func defaultFallback() throws { #expect(try EnvResolver.resolve("${X:-z}", env: [:]) == "z") }
    @Test func unsetThrows() throws {
        #expect(throws: MemSearchError.self) { _ = try EnvResolver.resolve("${X}", env: [:]) }
    }
    @Test func dollarEscape() throws { #expect(try EnvResolver.resolve("$$") == "$") }
    @Test func mixed() throws {
        #expect(try EnvResolver.resolve("${A}/${B:-x}/$$", env: ["A": "a"]) == "a/x/$")
    }

    @Test("malformed ${VAR:default} (missing dash) throws")
    func malformedDefaultSyntax() throws {
        #expect(throws: MemSearchError.self) {
            _ = try EnvResolver.resolve("${X:foo}", env: ["X": ""])
        }
        #expect(throws: MemSearchError.self) {
            _ = try EnvResolver.resolve("${X:foo}", env: [:])
        }
    }

    @Test("resolve preserves literal text around placeholders")
    func mixedLiterals() throws {
        let s = try EnvResolver.resolve("hello ${X} world", env: ["X": "swift"])
        #expect(s == "hello swift world")
    }
}
