/// Lightweight read-only snapshot of engine state, used by hosts (CLI `info`,
/// SwiftUI dashboards). Public so consumers in *sibling SwiftPM packages*
/// can compose it without reaching for `package`-scoped engine internals.
///
/// **Growth path:** future fields are *additive `let` properties* with
/// non-failable defaults — but Swift's auto-synthesized memberwise init does
/// **NOT** carry stored-property defaults into its parameter list. To keep
/// source compat for hosts that init `EngineSummary` in tests / previews
/// (`EngineSummary(sourceCount: 1, chunkCount: 1)`), always hand-write a
/// public init whose new parameters have defaults: e.g. v2 adds
/// `init(sourceCount:Int, chunkCount:Int, lastIndexedAt: Date? = nil)`.
/// Never rely on the implicit memberwise init.
public struct EngineSummary: Sendable {
    public let sourceCount: Int
    public let chunkCount: Int

    /// Hand-written init (not the implicit memberwise init) so future
    /// additive fields can land with defaults without breaking call sites.
    public init(sourceCount: Int, chunkCount: Int) {
        self.sourceCount = sourceCount
        self.chunkCount  = chunkCount
    }
}
