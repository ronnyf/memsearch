# Phase 0 — Notes

**Period:** 2026-05-20
**Status:** complete (with one deliverable deferred to Phase 1 entry)

## Surprises

- **`Task<Success, Failure>` is a struct** in Swift 6.4. The phasing doc and the design spec both used `if inFlight === task` to gate `defer` cleanup of the in-flight task. `===` is `AnyObject`-only and rejects `Task<S, F>`; the build failed at the line. Spike 0c replaced it with a monotonic generation counter — same semantics, different syntax. The mistake was repeating Apple's older sample-code pattern verbatim without checking against current SDK.
- **`.concurrentRequests` migrated between error enums** between macOS 26 and macOS 27. macOS 26's `LanguageModelSession.GenerationError` carries it (with a `Context` associated value); macOS 27+ moved it to a new `LanguageModelSession.Error` enum and deprecated the old surface. The phasing doc patch 2 and the design spec's mapping table assumed the macOS 27 surface only. Code that builds against macOS 26 deployment cannot use a typed `catch let e as LanguageModelSession.Error` clause — the type isn't visible to the compiler. Conditional cast (`e as? LanguageModelSession.Error`) inside an `#available` guard is the only working pattern.
- **`LanguageModelSession` accumulates a transcript across `respond` calls.** The design spec stored a single session for the actor's lifetime. Spike 0c's first stress run reproduced `GenerationError.exceededContextWindowSize` after roughly 100 short prompts. Recreating the session per `callRespond` resolved it cleanly. This is fundamental to the framework's "follow-up coherent conversation" design — a stateless summarizer needs to opt out of it.
- **`asg017/sqlite-vec` ships no `Package.swift`** in upstream. The SwiftPM integration path is "fork + add Package.swift wrapping the C source." Spike 0a's local fork at `/tmp/memsearch-spikes/sqlite-vec-fork/` validates the approach; Phase 1 picks fork-vs-vendor.
- **Static-link via `sqlite3_vec_init` direct call avoids the `load_extension` question entirely**, which was the centerpiece of Spike 0a's failure mode (a). The pivot landed during Spike 0a — the failure mode never actually triggered because we routed around it.
- **Spike 0a's reader-concurrency test showed only 2.55× speedup with 8 readers** rather than ~8×. The reason is workload-bound: SIMD KNN already saturates NEON within a single thread, leaving less headroom for thread-level parallelism. The `final class : Sendable` design choice over an actor still holds — readers do parallelize, just not linearly.
- **swift-transformers v1.3.3 was released 2026-05-16**, four days before this spike. The spec's "swift-transformers BGE-M3 Core ML availability" risk note is still accurate: the library exists and is usable, but `sentence-transformers/all-MiniLM-L6-v2` (the most popular embedding model) ships PyTorch + ONNX, not Core ML. Phase 2 still needs to pin a Core-ML-shipped default model.
- **Apple's `LanguageModelSession.GenerationError.guardrailViolation` triggers on benign prompts at ~0.1 % rate.** Spike 0c's 999/1000-success run had one false-positive guardrail rejection of the prompt "Worker N iter M: one sentence summary of: hello world." Phase 6's tests should not require 100 % success — only zero `singleFlightViolation`.
- **Swift Testing macros reject sibling `@available(...)` attributes.** `@Suite` and `@Test` build a compile-time test discovery table; `@available` interferes. Test struct/function-level `@available` is not allowed. Phase 6 must guard FoundationModels test bodies via runtime `#available` checks or by raising the Package.swift `platforms:` floor.

## Spec deltas applied

| Commit    | Description |
| --------- | ----------- |
| `eb74e49` | `callRespond` example gains a second catch clause; `MockEmbeddingProvider`'s `State` struct gains `latencyPerBatch: Duration?` and the `embed(_:)` body honors it via `try await Task.sleep(for:)` (the patch-7 prose was applied without code-block update originally). |
| `2f5a923` | `SQLiteVectorStore.init` replaces `try db.execute(sql: "SELECT load_extension('vec0')")` with a direct `sqlite3_vec_init(db.sqliteConnection, &errMsg, nil)` call. Imports gain `import SQLite3`. The "Open questions" entry on sqlite-vec distribution is resolved: source-link via custom SwiftPM wrapper. |
| `ca7dd71` | `FoundationModelsSummarizer` example: (1) generation counter replaces `inFlight === task`; (2) `instructions` stored in actor and `LanguageModelSession` recreated inside `callRespond`; (3) dual error-enum catch (`GenerationError` typed catch + `Error` conditional cast under `#available(macOS 27, ...)`); mapping tables reflect the SDK split. |

## Items deferred to later phases

- **Python ground-truth fixture (`python-top5.json` + `python-top5.json.sha256` + `manifest.json`).** Blocked at Phase 0 by network sandbox (`cdn-lfs.huggingface.co` and `cas-server.xethub.hf.co` not yet allowlisted; `memsearch[onnx]` extras also need `uv tool install --reinstall 'memsearch[onnx]'` to actually pull `onnxruntime` + `tokenizers` + `huggingface-hub` into the tool venv). Corpus and `queries.json` are committed; the top-5 dump is the missing piece. Phase 1 entry must close this before exercising the fixture cross-check.
- **End-to-end `.mlpackage` load (Spike 0b).** The actor-shape probe — the load-bearing risk — passes cleanly. End-to-end Core ML embed inference depends on which default model gets pinned at Phase 2 entry. The candidates ranked by preference: BGE-M3 (if a Core ML conversion ships); `apple/all-MiniLM-L6-v2-coreml` (or similar Apple-published Core ML conversion); custom `coremltools` conversion (last resort).
- **iOS Simulator compile gate for the spike scratch packages.** Phase 1's per-phase ritual introduces this; the spike packages target `[.macOS(.v14)]` only.
- **`asg017/sqlite-vec` upstream PR.** Spike 0a's static-link `Package.swift` wrapper is a candidate to upstream. Phase 1 decides fork-vs-vendor; if fork, the SwiftPM wrapper PR is the cleanest external contribution.

## Phase 1 entry checklist

- [ ] Spec is coherent (every Task 2 grep + every Spike 0a/0c patch grep passes).
- [ ] If `cdn-lfs.huggingface.co` and `memsearch[onnx]` extras are working, generate `tests/fixtures/python-baseline/python-top5.json` + `python-top5.json.sha256` + `manifest.json` per the deferred Phase 0 procedure.
- [ ] Confirm BGE-M3 vs MiniLM-L6 vs other for Phase 2's default Core ML model identifier; pin in `docs/superpowers/specs/` Risks section if a preference emerges.
- [ ] Decide: fork `asg017/sqlite-vec` and upstream the SwiftPM wrapper, or vendor `Sources/SQLiteVec/` inside this repo. Either way, the spike's working `sqlite-vec.h` rendering + `Package.swift` shape applies directly.
- [ ] Phase 1's `Package.swift` declares the canonical `platforms:` block — `[.macOS(.v14), .iOS(.v17), .visionOS(.v1)]` — and pins the iOS Simulator compile-gate command for use as a per-phase ritual.

## Phase 0 effort

~2 days as the phasing doc estimated, including the two side-trips (Apple Intelligence enablement + the in-flight switch from "executable + main.swift" to "library + Swift Testing test target"). The fixture deferral is the only material schedule slip; it carries into Phase 1 entry.
