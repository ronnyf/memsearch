# MemSearch Swift 6 Rewrite — Phasing Strategy

**Status:** draft (post-brainstorm, post-adversarial-review-loop-1)
**Date:** 2026-05-20
**Issue:** #1
**Companion:** [`2026-05-20-swift-rewrite-design.md`](2026-05-20-swift-rewrite-design.md) — the design spec this phasing implements.

## Premise

The Python `memsearch` library is in production with four plugin clients. The
Swift rewrite is greenfield (no migration required, no wire compatibility,
no time pressure). This buys us the freedom to phase deliberately: each
phase ships a coherent working subset, every phase ends green, and we can
stop after any phase and still have something useful.

## Methodology decisions

These decisions cut across every phase:

- **MVP shape:** library + minimal CLI. The first deliverable is a Swift
  Package + `memsearch` executable that can `index`/`search`/`info`
  against a real notes folder using SQLite + OpenAI embeddings.
- **Slicing:** vertical slices, MVP first. Each phase ships an end-to-end
  working subset; never an "infrastructure-only" phase.
- **Testing:** TDD for genuinely tricky pieces (chunker, RRF math, error
  lifting, GRDB transactions, FoundationModels single-flight, async actor
  init); test-after for trivial wiring (CLI flag plumbing, scanner
  enumeration, TOML loading).
- **Risk-spike upfront:** Phase 0 runs three throwaway spikes on the
  highest-external-dep risks before Phase 1 starts. **Spike 0c is hard-
  required**, not skip-able — see Phase 0 below.
- **Spec drift discipline:** if a phase reveals a spec error, fix the spec
  first (commit), then the implementation. Spec and code never diverge
  silently. **In-flight concurrency-pattern patches:** if the spec change
  invalidates a pattern already partly written, revert the impl to the
  most recent green commit before applying the spec fix; restart from the
  patched spec. Don't surgically patch concurrency code in place.
- **Platform validation:** v1 fully validates **macOS 14+** at runtime.
  iOS / visionOS are **compile-only** in v1; runtime validation deferred
  to v2 (see "Deferred to v2"). Every phase's success criteria are macOS-
  CLI-shaped intentionally; iOS-runtime issues will surface only when v2
  brings up an iOS test target.
- **SwiftUI appendix maintenance:** any phase that changes a `public`
  engine method signature on `MemSearch` (`index`, `indexStream`, `search`,
  `summarize`, `appendSummary`, `watch`) MUST update the design spec's
  SwiftUI integration appendix in the same commit. Hosts copy-paste from
  it; stale code there is its own bug.

## Phase map

| Phase | Topic                              | Effort     | Outcome                                                           |
| ----- | ---------------------------------- | ---------- | ----------------------------------------------------------------- |
| 0     | Spikes + spec patches              | ~2 days    | External-dep risks validated; spec patched (incl. `MemSearchError.unimplemented`) |
| 1     | MVP — library + minimal CLI        | ~2 wk      | First dogfoodable: `memsearch index/search/info` against SQLite + OpenAI |
| 2     | Core ML embedder                   | ~1 wk      | Offline embedding option; first-run model download lifecycle      |
| 3     | SwiftData store                    | ~1 wk      | Second backend; brute-force cosine via Accelerate                  |
| 4     | Watcher                            | ~1 wk      | `memsearch watch` running on macOS via FSEvents                    |
| 5     | ONNX + Ollama embedders            | ~1 wk      | All four embedders interchangeable                                 |
| 6     | Compact + summarizers              | ~2 wk      | OpenAI-compatible + FoundationModels; `summarize/appendSummary`    |
| 7     | Hardening + docs                   | ~1 wk      | Integration tests, benchmarks, README, CI matrix                   |

Total: ~9–10 weeks single-developer FTE (loop-2 review surfaced Phase 1
file-count + Phase 6 effort under-estimates; bumped accordingly).

## Phase 0 — Spikes + spec patches

Three throwaway experiments + spec patches. Code lives in
`/tmp/memsearch-spikes/`, NOT in the repo. Only result notes go to
`docs/superpowers/spikes/`.

### Spec patches (apply to design spec before any spike runs)

1. **Add `MemSearchError.unimplemented(String)` case.** Used by Phase 1 stubs
   for `summarize`/`appendSummary`/`watch`. Public, `Sendable`, **permanent
   in the public enum** — kept as a defensive default for any future
   protocol-level "not yet wired" surfaces. Format:
   `case unimplemented("summarize: implemented in Phase 6")`.
2. **Add `LLMError.singleFlightViolation(any Error & Sendable)` case** and
   map `LanguageModelSession.Error.concurrentRequests` to it (NOT to
   `.modelFailure`). Concurrent-requests is the framework's canonical
   "single-flight contract violated" signal; demoting it to a generic
   `.modelFailure` would mask future regressions of the actor pattern.
3. **Add `LanguageModelSession.Error` mapping** to the `LLMError` mapping
   table. Two catch clauses required in `callRespond`.
4. **Update HTTP cancellation pattern** in design spec's "Cancellation
   granularity per embedder" table: catch `URLError` with code
   `.cancelled` and **directly throw `CancellationError()`** —
   unconditional translation, no `Task.checkCancellation()` middleman
   (which would silently swallow non-Task-driven URL cancellations).
5. **Update Platforms claim** to reflect iOS/visionOS as compile-only-validated
   in v1.
6. **Add v1-status banner to SwiftUI integration appendix** noting iOS
   runtime is deferred to v2.
7. **Clarify Testing rule**: mocks MAY use `Task.sleep` to provide
   cancellation latency; the *test assertion* must not depend on timing.
   `MockEmbeddingProvider` gains a `latencyPerBatch: Duration?` field.

### Spike 0a — GRDB 7.x + sqlite-vec extension load + reader concurrency

**Risk:** macOS system SQLite ships with extension loading disabled by
default. AND the design's `final class : Sendable` + `DatabasePool` choice
depends on GRDB's reader concurrency working *with* sqlite-vec loaded.

**Approach:**

1. Minimal SwiftPM scratch package with `GRDB.swift 7.x` + `sqlite-vec`.
2. `Configuration.prepareDatabase { db in try db.execute(sql:
   "SELECT load_extension('vec0')") }`.
3. `CREATE VIRTUAL TABLE chunks USING vec0(embedding float[1024])`,
   INSERT one vector, run a KNN SELECT.
4. **Concurrent-readers test:** 8 parallel `Task`s each calling a short
   KNN SELECT. Verify (a) all return correct results, (b) wall-clock is
   meaningfully sub-linear in N (i.e., readers actually parallelize).

**Done when:** the KNN SELECT returns the inserted vector AND the
concurrent-readers test passes.

**Failure mode → spec patch:**
- (a) ship `SQLite3-static` SPM dep to bundle a permissive SQLite build,
  OR
- (b) use GRDB's `SQLiteCustomBuild` mode, OR
- (c) drop sqlite-vec, fall back to brute-force cosine over BLOB
  embeddings. **This invalidates Phase 1's deliverables** — the
  `MemSearchSQLite` store would have no `vec0` virtual table; hybrid
  search becomes "FTS5 + Swift cosine over BLOBs" rather than
  "ANN + BM25 RRF". Phase 1's effort and file count would change.
  Spec patch required before Phase 1 starts.
- (d) reader concurrency fails — switch `SQLiteVectorStore` to an
  `actor`. Spec patch.

### Spike 0b — swift-transformers Core ML embedding model + actor init shape

**Risk:** swift-transformers may not ship a usable Core ML BGE-M3
package; we may need a different default. AND the design's actor shape
for `CoreMLEmbedder` (`nonisolated let dimension: Int` + `nonisolated let
modelName: String` + `private let model/tokenizer` set inside `async throws
init`) needs validation before Phase 1 commits to the protocol's
`nonisolated var dimension: Int { get }` requirement.

**Approach:**

1. Attempt `AutoTokenizer.from(modelFolder: …)` against BGE-M3.
2. Attempt `MLModel(contentsOf: …)` against the corresponding
   `.mlpackage`.
3. Embed `"hello world"`, verify dimension matches docs.
4. If BGE-M3 unavailable, repeat with `all-MiniLM-L6-v2`.
5. **Actor-shape probe:** wrap (1)+(2) in a minimal
   `actor TestEmbedder` with `nonisolated let dimension: Int` set in
   `async throws init`. Call `someEmbedder.dimension` from a non-isolated
   context. Verify it compiles and returns the expected value.

**Done when:** an embedding model loads end-to-end AND the actor probe
compiles + reads `dimension` non-isolated.

**Failure mode → spec patch:** pin the working model; if the actor-shape
probe fails, fall back to `static func make(folder:) async throws ->
Self` factory pattern (cascades into all CoreMLEmbedder construction
sites).

### Spike 0c — FoundationModels single-flight stress test (HARD-REQUIRED)

**Risk:** the spec's chained-Task pattern still races; or
`LanguageModelSession` has constraints we missed.

**This spike is no longer skip-able.** If macOS 26 hardware is unavailable,
acquire it (loaner Mac, cloud runner, etc.) before Phase 0 completes. The
spec's single-flight pattern is the riskiest concurrency primitive in v1
and ships in Phase 6 — discovering it's wrong during Phase 6 is too late.

**Approach:**

1. Build a minimal `actor StressActor` with the spec's exact pattern
   (`inFlight: Task<String, Error>?`, spawn-then-assign,
   `[weak self]` capture, `SystemLanguageModel.default.isAvailable`
   check, two-catch-clause error handling).
2. Spawn 10 concurrent `Task`s each calling `actor.summarize(prompt:)`.
3. Run 100 iterations.

**Done criteria:**
- (a) **No `LanguageModelSession.Error.concurrentRequests`** over 1000 calls
  (10 concurrent × 100 iterations). Catch all `LanguageModelSession.Error`
  cases AND `LanguageModelSession.GenerationError` cases — `concurrentRequests`
  lives on the `Error` enum, not `GenerationError`.
- (b) **Queue ordering / latency invariant**: record `(start, end)`
  timestamps inside the actor's `summarize` per call. Assert request
  completion order matches request initiation order, OR p99 wall-clock
  latency under N=10 concurrent callers is within `T_serial × N × 1.2`.
  The pattern's correctness claim is *single-flight serialization*; the
  spike must observe that property, not just the absence of errors.

**Failure mode → spec patch:** revise the single-flight pattern; consult
Apple sample code; potentially switch to a different serialization
primitive.

### Phase 0 deliverables

- `docs/superpowers/spikes/2026-05-20-spike-0a-sqlite-vec.md`
- `docs/superpowers/spikes/2026-05-20-spike-0b-coreml-bge.md`
- `docs/superpowers/spikes/2026-05-20-spike-0c-foundationmodels.md`
- **Pinned Python ground-truth fixture** at `tests/fixtures/python-baseline/`:
  - `corpus/` — ~100 markdown files used as the comparison corpus.
  - `queries.json` — 5–10 frozen sample queries.
  - `python-top5.json` — Python `memsearch` top-5 results per query,
    computed once and committed. Records: Python version, embedding
    model name, embedder version, `pip freeze` snapshot.
  - This fixture is referenced by Phase 1 (criterion 6) and Phase 5
    (success criterion). Without it, Phase 1 ↔ Phase 5 measurements are
    irreproducible.
- Spec patches committed to design spec.
- `docs/superpowers/spikes/index.md` summarizing all results + fixture.

**Exit criterion:** all three spikes have a result note, the fixture is
pinned, and the design spec reflects any architectural pivots.

## Phase 1 — MVP (Library + minimal CLI)

The first vertical slice. Proves the architecture end-to-end.

**Spec dependency:** Phase 0a result. If Spike 0a's failure mode (c) was
hit (drop sqlite-vec), Phase 1's `MemSearchSQLite` deliverables and
effort estimate change — re-baseline before starting.

### Deliverables

**`MemSearch` library:**

- All public types (Models/, Errors/) with `LocalizedError` conformances —
  including `MemSearchError.unimplemented(String)` (added in Phase 0).
- All three protocols (`VectorStore`, `EmbeddingProvider`,
  `LLMSummarizer` — last unused but declared).
- `MemSearch<V, E>` engine with `init`, `index`, `indexStream`,
  `indexFile`, `search` implemented; `summarize` / `appendSummary` /
  `watch` declared but throw `.unimplemented("...: implemented in Phase N")`.
- `Chunker` (heading-based, deterministic, matches Python).
- `RRF.fuse` helper.
- `Scanner` (FileManager.enumerator).
- `Configuration` value types (TOML loading lives in CLI package).
- Mocks: `MockEmbeddingProvider` (final class), `MockVectorStore`
  (actor), `MockSummarizer` (struct) — package-visible, content-keyed
  failure injection.
- Error-lifting helper (private package).

**`MemSearchSQLite` library:**

- `SQLiteVectorStore` (final class : Sendable wrapping `DatabasePool`,
  per Spike 0a outcome).
- Schema + GRDB migrations.
- sqlite-vec extension loading via `Configuration.prepareDatabase`.
- FTS5 + bm25.
- `hybridSearch` running both queries inside one `pool.read { db in ... }`.
- `scan(filter:) -> AsyncThrowingStream<Chunk, any Error>` real impl.

**`MemSearchEmbeddersHTTP` library:**

- `OpenAIEmbedder` only (Ollama deferred to Phase 5).
- `URLSession.shared` async API.
- `URLError(.cancelled)` → `CancellationError` translation
  (via `try Task.checkCancellation()` after catch).

**`MemSearch-CLI` package:**

- `swift-argument-parser` entry point.
- Subcommands: `index`, `search`, `info`.
- TOML config loader (basic; full env-var resolution can wait).
- Programmatic init also supported (no TOML required) — the iOS path,
  even though we don't validate it at runtime in v1.
- Per-case dispatch — only 1 store × 1 embedder = 1 case in MVP.
- JSON output for `search`.

### Tests

- **TDD (red-green-refactor):**
  - Chunker (golden-file fixtures).
  - `RRF.fuse` math.
  - `ChunkID` stability.
  - Error-lifting helper (per `MemSearchError` constructor — proves the
    underlying cause survives lifting).
  - **`URLError(.cancelled)` translation**: `OpenAIEmbedder.embed(_:)` under
    `Task.cancel()` throws `CancellationError`, not
    `EmbeddingError.networkFailure`. Mocked URLSession. The embedder catches
    `URLError` with `code == .cancelled` and **directly throws `CancellationError()`**
    (do NOT route through `try Task.checkCancellation()` — that silently
    swallows non-Task-driven URL cancellations).
  - **`index()` matches `indexStream()`**: assert `index()` returns the
    same `IndexStats` as a hand-reduce over `indexStream()` events.
  - **`indexStream()` cancellation propagation**: between-files
    `try Task.checkCancellation()` surfaces as `CancellationError` mid-
    stream. `MockEmbeddingProvider` injects latency via its
    `latencyPerBatch: Duration` field; the test cancels mid-flight and
    `#expect(throws: CancellationError.self)`.
  - **Sendable compile gate** (separate from behavior tests): a one-line
    `@Test func sendableCompileGate()` that captures
    `MemSearch<MockVectorStore, MockEmbeddingProvider>` across a
    `Task {}` boundary. Body does nothing else — the compile is the
    assertion. Verifies the engine + actor-V composition is `Sendable`.
  - **Engine round-trip with mocks** (separate behavior test): construct
    `MemSearch<MockVectorStore, MockEmbeddingProvider>`, exercise
    `index()` + `search()` end-to-end against canned mock data. Asserts
    correctness, not Sendability.
  - **`SQLiteVectorStore.scan` end-to-end smoke test**: drain the stream
    against a real GRDB-backed store. Compile-validates the `@Sendable`
    capture in the GRDB-wrapping closure (this is the only consumer of
    `scan` until Phase 6, so we proxy-validate it here).
  - **SQLite CRUD** + **`hybridSearch` single-tx invariant** (lands
    after schema scaffold; cannot TDD from cold start).

- **Test-after:** Scanner, CLI flag plumbing, TOML loader, programmatic
  init plumbing.

**TDD ordering inside Phase 1:** chunker → RRF → ChunkID → error-lifting
→ HTTP cancellation → engine reduce-invariant → engine cancellation →
actor-boundary Sendable → SQLite schema + CRUD → hybridSearch single-tx
→ scan smoke. Items after engine-reduce-invariant depend on prior
infrastructure; running them out of order will spin.

### Success criteria

1. `swift test` green across all test targets.
2. `swift run memsearch index --paths some-fixtures` succeeds against a
   100-file fixture.
3. `swift run memsearch search "query"` returns top-K with sane scores.
4. `swift run memsearch info` shows chunk count + DB path.
5. **Idempotency:** re-running `index` (no `--force`) results in zero
   new chunks.
6. **Cross-check:** same fixture indexed by Python `memsearch`; for 5
   sample queries the Swift top-3 overlap with Python top-5 ≥ 60%.
7. **Cancellation:** `URLError(.cancelled)` test surfaces
   `CancellationError`, not `MemSearchError.embedding(.networkFailure)`.

### What we explicitly skip

Core ML, SwiftData, watcher, other embedders, compact/summarizers,
String Catalog localization, performance benchmarks, integration tests
across phases, **iOS-runtime validation** (deferred to v2).

### Phase 1 effort

~2 weeks single-developer; ~45–50 source files + ~12–15 test files.
Loop-2 review revised the original 30-file estimate up; the deliverables
list legitimately covers ~12 model types + 4 errors + 3 protocols + 4
engine extensions + chunker/RRF/scanner/configuration + 3 mocks +
error-lifting + SQLite (5) + HTTP (3) + CLI (6).

## Phase 2 — Core ML embedder (~1 wk)

- **Add:** `MemSearchEmbeddersCoreML` module with `CoreMLEmbedder`
  actor; `async throws` init (`Tokenizer.from(modelFolder:)` is async).
- **Wire:** `preDownload(model:)` API; model dir at `Application
  Support/MemSearch/Models/` with `isExcludedFromBackupKey = true`.
- **CLI dispatch:** 2 cases (1 store × 2 embedders).
- **Tests (TDD):**
  - Dimension precondition.
  - Async model load, batch correctness via deterministic golden vectors.
  - **Per-batch cancellation**: `Task.cancel()` mid-`embed(_:)` causes
    the next batch to throw `CancellationError`; previous batches'
    results are not surfaced. (Compute embedders' cancellation contract
    is per-batch only; document and enforce.)
  - **Engine + actor-E Sendable assertion**: construct
    `MemSearch<SQLiteVectorStore, CoreMLEmbedder>`, pass across a Task
    boundary. Compile-time check.
- **Success:** `memsearch index --embedder coreml` works offline; first
  run downloads, second run uses cache.
- **Spec dependency:** Phase 0b spike result — default model identifier
  is whatever 0b validated. Actor init shape verified clean by 0b.

## Phase 3 — SwiftData store (~1 wk)

- **Add:** `MemSearchSwiftData` with `actor SwiftDataVectorStore:
  ModelActor` (manual, no macro), `StoredChunkRecord` `@Model`,
  brute-force cosine via Accelerate. **`vDSP_dotpr` OR `vDSP.dot`** —
  the implementer chooses; the spec doesn't over-constrain.
- **CLI dispatch:** 4 cases (2 stores × 2 embedders).
- **Tests (TDD):**
  - CRUD.
  - **Cosine correctness against numpy reference values** — committed
    fixture of (vector_a, vector_b, expected_cosine) tuples computed in
    Python with explicit float64 → float32 cast, asserted to 6 decimal
    places. This is the *only* correctness gate for the SwiftData
    backend — pinning to numpy is the ground truth.
  - Manual ModelActor isolation under concurrent search.
  - Sendable compile gate for `MemSearch<SwiftDataVectorStore, OpenAIEmbedder>`.
- **Success:**
  - SwiftData passes the numpy-anchored cosine test.
  - SwiftData top-K against the pinned Python fixture
    (`tests/fixtures/python-baseline/`) returns at least one of the
    Python top-5 in its top-5 for each query (same anchor as Phase 5,
    decoupled from SQLite).
  - Performance acceptable at 50k chunks.
- **Note:** dense-only — no BM25; `score = denseScore`. We do **not**
  cross-validate against `SQLiteVectorStore` here — that would conflate
  algorithmic difference (hybrid vs. dense-only) with cosine
  correctness. Numpy + Python-baseline are independent ground-truth
  sources.

## Phase 4 — Watcher (~1 wk)

- **Add:** `FileWatcher` actor with FSEvents (macOS,
  `kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer`
  — flag names per Apple's CoreServices headers; see
  https://developer.apple.com/documentation/coreservices/fseventstreamcreateflags)
  + DispatchSource (iOS) gated by `#if os()`. `MemSearch.watch()`
  throwing init returning `AsyncStream<IndexEvent>`. Debouncer.
- **CLI:** `memsearch watch` subcommand prints `IndexEvent` JSON per
  line.
- **Tests (TDD):**
  - Golden-path created/modified/deleted using `confirmation` over a
    tempdir.
  - **Automated retain-cycle test** (using deinit instrumentation, NOT
    polling): add a `package`-only "watcher deinitialized" hook — a
    closure stored on `FileWatcher` invoked from `deinit`. Use
    `confirmation { confirmed in ... drop the stream consumer ... await consumer.value }`
    so `deinit`'s `confirmed()` call fires inside the closure body
    before it returns. This matches `confirmation`'s real semantics
    (event count) and avoids polling/timing assertions.
- **Success:**
  - `memsearch watch` runs; mutations debounce → re-index.
  - Ctrl+C cleanly stops; no leaked fds (verified via `lsof` snapshot
    in test or release-checklist).
  - Automated retain-cycle test passes.

## Phase 5 — ONNX + Ollama embedders (~1 wk)

- **Add:** `MemSearchEmbeddersONNX` with `ONNXEmbedder` actor;
  `OllamaEmbedder` (final class) into `MemSearchEmbeddersHTTP`
  (auto-detects dimension via trial embed in async init).
- **CLI dispatch:** 8 cases (2 × 4). Hand-written acceptable; macro
  generation deferred to Phase 6/7 if it gets unwieldy.
- **Tests (TDD):**
  - ONNX model load + batch.
  - **ONNX per-batch cancellation** (mirror of Phase 2 test).
  - Ollama trial-embed dimension detection (mocked URLSession).
  - **Regression: existing `OpenAIEmbedder` strict-concurrency tests
    pass unchanged** after refactoring shared HTTP utilities. If shared
    helpers are introduced, declare them `@Sendable` (closures) or
    `Sendable`-conforming (types) at the point of extraction.
- **Success:**
  - All 4 embedders produce non-empty top-K results without crashing
    on a normal fixture.
  - Each embedder's top-3 contains at least one of the
    Python-`memsearch` top-5 results (anchored to ground truth, not to
    other embedders — different model families have legitimate
    cross-model variance).

## Phase 6 — Compact + summarizers (~2 wk)

Loop-2 review bumped this from 1.5 to 2 wk. Scope: 2 summarizers, two-error-
enum mapping, atomic file ops, `dateStamp` capture, 16-branch CLI dispatch
(consider macro generation), concurrent stress test.

- **Pre-step:** if Spike 0c was somehow not run during Phase 0 (it should
  have been — it's hard-required), run it now using the same criterion
  before any other Phase 6 work begins.
- **Add:** `OpenAICompatibleSummarizer` (final class).
  `FoundationModelsSummarizer` actor with the spec's corrected
  single-flight pattern (Spike 0c validated). `LanguageModelSession.GenerationError`
  AND `LanguageModelSession.Error` → `LLMError` mapping per spec
  (two catch clauses).
- **Engine:** `summarize(...) -> CompactedSummary` (with `dateStamp:
  Date`) + `appendSummary(_:to:)` (atomic temp-file + rename).
- **CLI:** `memsearch compact` with `--llm`, `--source`, `--preview`
  flags. `--preview` prints summary without writing.
- **CLI dispatch:** 16 cases (2 × 4 × 2 with `#available` gating on the
  FoundationModels-using arms). Strongly consider macro generation now.
  If a macro is built, treat it as a sub-deliverable in this phase
  (SwiftSyntax dep, MacroPlugin target setup, expansion testing — real
  work).
- **Tests (TDD):**
  - End-to-end summarize + appendSummary + re-index.
  - `dateStamp` survives next-day-append (filename + header derive from
    `summary.dateStamp`, never wall clock).
  - Concurrent stress test on `FoundationModelsSummarizer`. **Catch all
    framework errors**, not just `GenerationError`. **`#expect` zero
    occurrences of `LLMError.singleFlightViolation`** specifically —
    not just zero generic failures. CI-skipped on runners without
    macOS 26 SDK.
- **Success:**
  - `memsearch compact --source path.md --llm openai` writes daily
    memory log.
  - `--llm foundation-models` works on macOS 26.
  - Stress test green on macOS 26 hardware (zero
    `singleFlightViolation`).
  - **iOS 26 SDK compile gate**: `xcodebuild build -destination 'generic/platform=iOS Simulator'`
    against the iOS 26 SDK. Verifies `@available(iOS 26, *)` annotation,
    `SystemLanguageModel.default` availability surface, and
    `LanguageModelSession.Error.concurrentRequests` symbol exposure on iOS.
    Runtime on iOS 26 not exercised in v1 (deferred per v2 backlog);
    compile gate is non-negotiable.

## Phase 7 — Hardening + docs (~1 wk)

- **Add:**
  - Integration tests (full index → search → compact → re-index).
  - Benchmarks (chunks/sec indexed, query p50/p99 latency).
  - README with Quick Start + SwiftUI integration.
  - **CI matrix** — per-module iOS support table:

    | Module                      | iOS compile in v1 | Notes                                                                 |
    | --------------------------- | ----------------- | --------------------------------------------------------------------- |
    | `MemSearch`                 | required          | Foundation only.                                                      |
    | `MemSearchSQLite`           | required          | GRDB iOS-supported. **sqlite-vec extension load on iOS** verified by Phase 0a addendum or Phase 1 entry-criterion. If iOS sandbox blocks `load_extension`, mark "best-effort" and add to v2 backlog. |
    | `MemSearchSwiftData`        | required          | iOS-native.                                                           |
    | `MemSearchEmbeddersHTTP`    | required          | URLSession.                                                           |
    | `MemSearchEmbeddersCoreML`  | required          | swift-transformers iOS-shipped (verified via Spike 0b actor probe).   |
    | `MemSearchEmbeddersONNX`    | best-effort       | Pending swift-onnxruntime iOS verification. If it doesn't compile in v1, mark explicitly and defer to v2. |
    | `MemSearch-CLI` executable  | excluded          | macOS-only (TOML loader, env-var resolution, file paths).              |

  - **FoundationModels runtime test runner specification:**
    GitHub Actions' macOS 26 runner availability is uncertain; if
    unavailable at CI bring-up, gate via a self-hosted runner or
    scheduled nightly local run with result reporting. Don't silently
    skip.
- **Polish:**
  - `LocalizedError` strings reviewed.
  - Full env-var resolution in TOML loader.
  - Macro-based CLI dispatch if hand-written hit pain points.
  - LICENSE / CONTRIBUTING if missing.
- **Success:**
  - README sufficient for a new contributor to integrate the library.
  - Benchmarks committed.
  - CI green; all phases' tests pass together.
  - Per-module iOS compile matrix all green (except documented
    "best-effort" / "excluded").
  - **Strict-concurrency contract validation note:** the
    `FoundationModelsSummarizer` actor's strict-concurrency contract is
    compile-validated on every CI runner that has the macOS 26 SDK,
    independent of the runtime stress test. Document this distinction.

## Cross-cutting concerns

### Per-phase rituals

Every phase ends with:

1. `swift test` green.
2. `swift build` green for every product.
3. **iOS Simulator compile gate**: `xcodebuild build -scheme <module> -destination 'generic/platform=iOS Simulator'`
   green for every iOS-required module per the Phase 7 support matrix.
   Failure indicates the phase introduced a macOS-only API call without
   `#if os(macOS)` gating — fix in this phase, do not defer. Phase 4
   (FSEvents/DispatchSource) and Phase 6 (FoundationModels iOS 26 SDK)
   are the highest-risk phases for this gate.
4. Commit, push.
5. `docs/superpowers/phases/phase-N-notes.md` capturing surprises,
   spec deltas, deferred items.

### What we explicitly do NOT do during Phases 1–6

- Add features beyond the spec.
- Style refactors of code we didn't touch.
- Build SwiftUI host apps.
- Build iOS test targets (deferred to v2).
- Write OpenClaw / OpenCode / Codex plugin replacements (post-v1).
- Premature performance optimization (real numbers come from Phase 7
  benchmarks).

### Deferred to v2

Reconciled against the design spec's "Out of scope (v1, may revisit)" and
"Non-goals" sections. v2 work picked up post-v1:

- Cross-encoder reranker.
- BM25 inside SwiftData backend.
- Token streaming through `LLMSummarizer`.
- `MLXLocalSummarizer`.
- On-disk format migration from Python `memsearch`.
- Plugin clients (Claude Code, OpenCode, Codex, OpenClaw).
- watchOS / tvOS support.
- TOML String Catalog localization.
- **iOS / visionOS runtime validation** — XCTest on `iphonesimulator`,
  per-phase iOS test gates, dogfood iOS app target. v1 ships
  compile-only-validated; v2 brings up the iOS test surface.
- **SwiftUI `@Observable` view-model wrapper** as a first-party module
  (the design spec's appendix shows the pattern; a sibling
  `MemSearchUI` module is a v2 add).
- **Read-only / remote `VectorStore` backends** — re-introduce the
  role-protocol split (`VectorIndex` / `VectorMutator` /
  `VectorIntrospection`) when there's a real consumer. v1 keeps the
  composite protocol.
- **`AsyncThrowingStream<_, Failure>` typed Failure narrowing** — when
  Swift 6.1 is the toolchain floor, narrow the streams (`scan`,
  `indexStream`) from `any Error` to typed errors.

### Spec patches during phases

If a phase reveals a spec error:

1. Fix the spec first; commit with `docs: spec patch — <reason>`.
2. Update the SwiftUI integration appendix in the same commit if the
   change touches a `public` engine method signature.
3. Then update the implementation.

**In-flight concurrency-pattern patches:** if the spec change
invalidates a pattern already partly written (e.g., Spike 0c reveals a
race in the chained-Task pattern mid-Phase-6), revert the implementation
to the most recent green commit before applying the spec fix. Don't try
to surgically patch concurrency code in place — partial corrections
embed half-fixed reentrancy semantics.

Spec is the single source of truth for design decisions; code is the
single source of truth for behavior; they should match.

## v2 iOS validation backlog (entry criteria)

Before v2 declares iOS support runtime-validated, the team must exercise
the following — concrete entry criteria for the v2 milestone, not "nice
to have":

1. **Security-scoped URL lifecycle**: `mem.search` / `mem.indexStream`
   against a `UIDocumentPicker`-sourced URL, including the
   URL-invalidation path (host fails to call
   `startAccessingSecurityScopedResource` → engine surfaces a clean
   error, not a crash).
2. **`mem.watch()` on iOS DispatchSource path**: per-fd
   `makeFileSystemObjectSource` registration works inside the app
   sandbox. The design's "throws on iOS init failure" contract surfaces
   correctly when security-scoped URLs are invalid. Cross-platform
   retain-cycle test (the macOS FSEvents test does not cover the iOS
   DispatchSource path).
3. **`BGAppRefreshTask` re-index**: integration test of host calling
   `mem.index()` from a `BGAppRefreshTask` handler — verifies async
   cancellation, foreground re-entry, per-file idempotency on iOS.
4. **Programmatic init + Keychain config**: `MemSearch` constructed with
   paths from `containerURL()`, `OpenAIEmbedder` with key from Keychain.
   Full index/search/compact cycle.
5. **`FoundationModelsSummarizer` on iOS 26 device**: parity with macOS
   26 stress test — same single-flight invariant, zero
   `LLMError.singleFlightViolation`, queue-ordering / latency invariant.
6. **Per-module iOS XCTest target**: every module marked "iOS required"
   in the Phase 7 support matrix gets a `*Tests` target on
   `iphonesimulator`.
7. **`isExcludedFromBackupKey` round-trip**: assert the flag survives
   on a real iOS sandbox container path (`Application Support` resolved
   via `FileManager.url(for: .applicationSupportDirectory, ...)`).
8. **SwiftUI integration appendix snippet**: the design spec's appendix
   compiles against an iOS app target and runs end-to-end on simulator —
   the v1-status banner can then be removed.

## After Phase 7

- v1 release (tag, GitHub release).
- v2 priorities decided based on real usage. **iOS runtime validation
  is the highest-priority v2 deliverable** — see the backlog above for
  entry criteria.
- Plugin client work (post-v1) is its own brainstorm → spec → plan
  cycle, separate from this rewrite.
