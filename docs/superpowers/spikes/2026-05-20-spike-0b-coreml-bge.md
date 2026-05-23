# Spike 0b — swift-transformers Core ML + actor init shape

**Date:** 2026-05-20
**Phase:** 0
**Outcome:** **PASS** (load-bearing criterion green; secondary criterion partially validated)
**Risk it covers:** swift-transformers usability + the design spec's actor init shape (`nonisolated let dimension: Int` set inside `async throws init`, readable from a non-isolated context).

## Environment

- macOS: 26.6
- Swift: 6.4
- macOS SDK: 27.0
- swift-transformers: **v1.3.3** (released 2026-05-16, four days before this spike). `import Hub`, `import Tokenizers` — both imports resolve cleanly under Swift 6 strict concurrency.
- Tested platforms: macOS only (the spike's `Package.swift` declares `[.macOS(.v14)]`; iOS-Simulator gate validation belongs in Phase 7's CI matrix).

## Result

### Sub-criterion 1 — actor init shape (LOAD-BEARING)

**PASS** (~1 ms).

The design spec's `EmbeddingProvider` protocol requires
`nonisolated var dimension: Int { get }`. The only way an `actor` can
satisfy that is via `nonisolated let dimension: Int` set inside the actor's
init. The spike's `TestEmbedder` mirrors the design spec's `CoreMLEmbedder`
shape exactly:

```swift
public actor TestEmbedder {
    public nonisolated let modelName: String
    public nonisolated let dimension: Int
    private let model: MLModel?
    private let tokenizer: (any Tokenizer)?

    public init(modelName: String, dimension: Int) { … }       // bare-shape
    public init(modelFolder: URL, modelName: String, dimension: Int) async throws { … }   // full-shape
}
```

A non-isolated read worked without `await`:

```swift
let probe = TestEmbedder(modelName: "spike-probe", dimension: 1024)
let dim: Int = probe.dimension      // compiles, no `await`
#expect(dim == 1024)                // ✓
```

Conclusion: the design's CoreMLEmbedder + ONNXEmbedder `nonisolated let`
init pattern works under Swift 6 + `swiftLanguageMode(.v6)`. **No
static-factory pivot required.** Phase 2's `CoreMLEmbedder` and Phase 5's
`ONNXEmbedder` keep the spec's exact init signature.

### Sub-criterion 2 — swift-transformers symbols linkable

**PASS** (~1 ms).

`HubApi`, `Hub`, `Hub.RepoType`, `AutoTokenizer` all resolve under
`import Hub` / `import Tokenizers`. swift-transformers v1.3.3 builds clean
under Swift 6.4 strict concurrency mode (Swift 6 language mode).

### Sub-criterion 3 — Hub.snapshot end-to-end (PARTIAL)

**Partial PASS** (1.06 s).

The opt-in download test (`MEMSEARCH_SPIKE_0B_DOWNLOAD=1`) successfully
called `HubApi().snapshot(from:matching:)` against
`sentence-transformers/all-MiniLM-L6-v2` and landed
`tokenizer.json` + `config.json` in
`~/Documents/huggingface/models/sentence-transformers/all-MiniLM-L6-v2/`.

**The repo does NOT ship a `model.mlpackage`** — `sentence-transformers`
publishes PyTorch + ONNX, not Core ML. The spike's matching glob
(`*.mlpackage/**`) selected nothing on the server side, so the
`MLModel(contentsOf:)` path was not exercised. The test's
"tokenizer-only success" branch fired and passed.

**This is a real Phase 2 finding, not a spike failure.** The phasing doc's
Risks section already calls this out:

> **swift-transformers BGE-M3 Core ML availability** — `CoreMLEmbedder`'s
> default model identifier depends on swift-transformers exposing a Core
> ML package for BGE-M3 (not just the tokenizer). If unavailable, fall
> back to a smaller verified model (e.g. `all-MiniLM-L6-v2` Core ML
> conversion); document the upgrade path. **Verify before locking in.**

End-to-end `.mlpackage` loading is deferred to Phase 2, where the actual
default model gets pinned and a real Core ML conversion is identified.
Candidate Phase 2 default models (in order of preference):

1. `BAAI/bge-m3` — first preference. Confirm Core ML availability before Phase 2 starts.
2. `apple/all-MiniLM-L6-v2-coreml` (or similar Apple-published Core ML conversion).
3. Custom Core ML conversion via `coremltools` (last resort; spec patch + extra Phase 2 work).

## Spec implications

- **None**. The design's `CoreMLEmbedder` definition and the
  `EmbeddingProvider`-required `nonisolated var dimension: Int { get }` shape
  hold. The Risks section's BGE-M3 caveat stays accurate; Phase 2 resolves the
  exact default model.

## Notes

- Phase 2 entry checks should include a real `.mlpackage` load + a forward
  pass on `"hello world"` against the chosen default model. The spike code
  in `/tmp/memsearch-spikes/spike-0b/` is a working basis for that.
- Hub.snapshot via swift-transformers worked cleanly with `matching:` glob
  patterns. No auth required for public models. The cache path was
  `~/Documents/huggingface/models/...` — Phase 2's actual implementation
  should redirect this to `Application Support/MemSearch/Models/` per
  the spec (a `HubApi` configuration override or similar).
- Build hit one mistake worth recording: the test target had to depend on
  `Hub` and `Tokenizers` directly, plus `import` them in the test file —
  re-exporting through the Spike0b library wasn't enough. Phase 2's
  `MemSearchEmbeddersCoreML` test target needs the same setup.
- Spike scratch lives at `/tmp/memsearch-spikes/spike-0b/` — not committed.
