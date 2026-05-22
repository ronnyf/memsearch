import Foundation
import MemSearch

enum EnvResolver {
    /// Resolves `${VAR}` and `${VAR:-default}` placeholders in the input string.
    /// Literal `$` is escaped as `$$`. Throws `MemSearchError.configurationInvalid`
    /// if a `${VAR}` (no default) names an unset environment variable, or if the
    /// placeholder is malformed (`${VAR:default}` without the `-` is rejected).
    static func resolve(
        _ s: String,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            // $$ → $
            if s[i] == "$",
               s.index(after: i) < s.endIndex,
               s[s.index(after: i)] == "$" {
                out.append("$")
                i = s.index(i, offsetBy: 2)
                continue
            }
            // ${...}
            if s[i] == "$",
               s.index(after: i) < s.endIndex,
               s[s.index(after: i)] == "{" {
                guard let close = s[i...].firstIndex(of: "}") else {
                    throw MemSearchError.configurationInvalid("unterminated ${...} in: \(s)")
                }
                let inner = s[s.index(i, offsetBy: 2)..<close]
                let parts = inner.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(parts[0])
                if parts.count == 2 {
                    guard parts[1].hasPrefix("-") else {
                        throw MemSearchError.configurationInvalid(
                            "malformed env-var placeholder: ${\(inner)} (default form is ${VAR:-fallback})"
                        )
                    }
                    out.append(env[name] ?? String(parts[1].dropFirst()))
                } else if let v = env[name] {
                    out.append(v)
                } else {
                    throw MemSearchError.configurationInvalid("environment variable \(name) not set")
                }
                i = s.index(after: close)
                continue
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }
}
