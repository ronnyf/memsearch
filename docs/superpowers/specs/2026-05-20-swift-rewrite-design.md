# MemSearch Swift 6 Rewrite — Design

**Status:** draft (post-brainstorm, post-adversarial-review-loops 1+2)
**Date:** 2026-05-20
**Issue:** #1

## Goals

Port the Python `memsearch` library to Swift 6 as an Apple-platform-idiomatic
package. Not a literal port — fresh API in Swift idioms, leveraging native
Apple primitives where they're a better fit.

**In scope (v1):**

- Library: chunker, indexing, hybrid search, embeddings, file watcher, LLM
  summarization, configuration.
- Two open-source vector store backends: SQLite (GRDB + FTS5 + sqlite-vec) and
  SwiftData.
- Four embedding providers, each in its own module: Core ML (default), HTTP
  (covers OpenAI + Ollama + any OpenAI-compatible server), ONNX Runtime.
- Two LLM summarizers: OpenAI-compatible HTTP and on-device FoundationModels
  (gated by availability).
- CLI executable (separate SPM package).

**Out of scope (v1, may revisit):**

- Cross-encoder reranker.
- BM25 inside the SwiftData backend.
- Token streaming through the summarizer protocol.
- Migration tools from the Python on-disk format.
- Plugin clients (Claude Code, OpenCode, etc.).
- A SwiftUI `@Observable` view-model wrapper. Hosts integrate per the
  documented patterns (see "SwiftUI integration").
- Read-only / remote vector backends. Re-introduce a role-protocol split
  for `VectorStore` when there's a real consumer.

## Non-goals

- Linux compatibility. macOS + iOS family only.
- Python interop.
- Wire-compatibility with Python `memsearch`'s on-disk format.
- watchOS / tvOS support.

## Platforms

- **macOS 14+** — fully tested in v1 (CLI + library).
- **iOS 17+ / visionOS 1+** — *compile-only verified in v1; runtime untested.*
  The library is designed and gated for these platforms (security-scoped
  URLs, sandbox container paths, Keychain-sourced credentials, FoundationModels
  iOS path), but actual iOS-runtime validation (XCTest on `iphonesimulator`,
  real-device dogfooding) is **deferred to v2**. Hosts integrating on iOS in
  v1 should expect to discover and report runtime issues. See the phasing doc
  for the explicit per-phase iOS-validation deferral.

`FoundationModelsSummarizer` requires macOS 26 / iOS 26 / visionOS 26 and an
Apple Intelligence-capable device — gated behind `@available`. Explicitly
unavailable on watchOS / tvOS (the Apple Watch path uses a cloud-backed model
and `SystemLanguageModel.default` is not exposed).

The file watcher is best-effort on iOS / visionOS — see "Apple platform
notes".

## Risks

- **swift-transformers BGE-M3 Core ML availability** — `CoreMLEmbedder`'s
  default model identifier depends on swift-transformers exposing a Core ML
  package for BGE-M3 (not just the tokenizer). If unavailable in May 2026,
  fall back to a smaller verified model (e.g. `all-MiniLM-L6-v2` Core ML
  conversion); document the upgrade path. Verify before locking in.
- **AsyncThrowingStream typed Failure** — typed `Failure` parameter on
  `AsyncThrowingStream` constructors lands in Swift 6.1; v1 ships against
  6.0 toolchain so streams use `any Error`. When 6.1 is the floor, narrow.

## Architecture

### Package layout

Two SPM packages:

```
Package: MemSearch (library package)
  swiftLanguageModes: [.v6]
  upcomingFeatures: [.ApproachableConcurrency]

  Modules
  ├── MemSearch                    library  (protocols, chunker, engine, watcher, compact, config, RRF helper)
  ├── MemSearchSQLite              library  (SQLite store via GRDB + FTS5 + sqlite-vec)
  ├── MemSearchSwiftData           library  (SwiftData store with Accelerate cosine — manual ModelActor)
  ├── MemSearchEmbeddersCoreML     library  (swift-transformers + Core ML)
  ├── MemSearchEmbeddersONNX       library  (swift-onnxruntime)
  └── MemSearchEmbeddersHTTP       library  (OpenAI-compatible + Ollama; URLSession only)

Package: MemSearch-CLI (executable package; depends on MemSearch package)
  └── memsearch                    executable  (swift-argument-parser CLI)
```

Library consumers depending on `MemSearch + MemSearchSQLite +
MemSearchEmbeddersHTTP` skip swift-transformers, ONNX runtime, SwiftData, and
CLI deps entirely.

### External dependencies

| Module                          | Dependencies                                  |
| ------------------------------- | --------------------------------------------- |
| `MemSearch`                     | (Foundation only)                             |
| `MemSearchSQLite`               | GRDB.swift 7.x, sqlite-vec                    |
| `MemSearchSwiftData`            | (system: SwiftData, Accelerate)               |
| `MemSearchEmbeddersCoreML`      | swift-transformers (system: CoreML)           |
| `MemSearchEmbeddersONNX`        | swift-onnxruntime                             |
| `MemSearchEmbeddersHTTP`        | (system: URLSession)                          |

CLI package adds: swift-argument-parser, swift-toml.

### Module access

`public` is reserved for the curated external API surface. Engine-internal
references (`store`, `embedder` on `MemSearch`) are `package`-visible only.
RRF helpers, mocks, and watcher internals are `package`. Cross-module
internals across our libraries use `package` — sufficient because all
libraries live in the same SPM package.

## Core types

```swift
public struct ChunkID: Hashable, Sendable {
    public let rawValue: String
    package init(_ rawValue: String) { self.rawValue = rawValue }   // package: only chunker mints IDs
}

public struct Chunk: Sendable, Hashable {
    public let id: ChunkID
    public let source: URL
    public let heading: String
    public let headingLevel: Int
    public let startLine: Int
    public let endLine: Int
    public let content: String
    public let contentHash: String   // SHA-256 of content
}

public struct Embedding: Sendable {
    public let values: [Float]
    public var dimension: Int { values.count }

    /// - Postcondition: `values.count == expectedDimension`
    /// - Throws: `EmbeddingError.dimensionMismatch` if violated
    public init(values: [Float], expectedDimension: Int) throws(EmbeddingError) {
        guard values.count == expectedDimension else {
            throw .dimensionMismatch(expected: expectedDimension, got: values.count)
        }
        self.values = values
    }
}
// NOTE: not Hashable — [Float] hashing has NaN reflexivity hazards and large
// vectors are expensive to hash.

public struct StoredChunk: Sendable {
    public let chunk: Chunk
    public let embedding: Embedding
}

public struct SearchHit: Sendable, Hashable {
    public let chunk: Chunk
    public let score: Float           // [0, 1]; equals denseScore on dense-only backends
    public let denseScore: Float?
    public let bm25Score: Float?
}

public struct HybridQuery: Sendable {
    public let queryText: String
    public let queryEmbedding: Embedding
    public let topK: Int
    public let filter: SourceFilter?
    public let rrfK: Int              // default 60
}

public struct SourceFilter: Sendable {
    public let prefix: URL
}

public struct IndexStats: Sendable {
    public let filesScanned: Int
    public let chunksAdded: Int
    public let chunksRemoved: Int
    public let failedFiles: [URL]
}

public struct ChunkingPolicy: Sendable {
    public let maxChunkSize: Int       // characters
    public let overlapLines: Int

    public static let `default` = ChunkingPolicy(maxChunkSize: 1500, overlapLines: 2)
}

/// Per-file engine outcome, streamed by `MemSearch.indexStream(...)` and `MemSearch.watch()`.
/// Counts are surfaced so `index()` can reduce over `indexStream()` to populate `IndexStats`.
public enum IndexEvent: Sendable {
    case indexed(URL, added: Int, removed: Int)    // added = new upserts; removed = stale deletes within the file
    case removed(URL, chunkCount: Int)              // orphaned-source cleanup
    case failed(URL, IndexFileError)
}

/// Errors that can occur on a single file during indexing.
public enum IndexFileError: Error, Sendable {
    case embedding(EmbeddingError)
    case store(VectorStoreError)
    case scan(any Error & Sendable)
    case chunking(any Error & Sendable)
}
```

`WatchEvent` (raw FS events) is `package`-only; only `FileWatcher` consumers
inside the library see it.

## Protocols

```swift
public protocol VectorStore: Sendable {
    /// Synchronous, nonisolated — backends store the value at construction.
    nonisolated var dimension: Int { get }

    func upsert(_ records: [StoredChunk]) async throws -> Int
    func hybridSearch(_ query: HybridQuery) async throws -> [SearchHit]
    /// Stream every chunk matching the optional filter. Stream's Failure is
    /// `any Error` (Swift 6.0 stdlib limitation; narrow when 6.1 is the floor).
    func scan(filter: SourceFilter?) -> AsyncThrowingStream<Chunk, any Error>
    func indexedSources() async throws -> Set<URL>
    func chunkIDs(forSource: URL) async throws -> Set<ChunkID>
    func delete(ids: [ChunkID]) async throws -> Int
    func delete(source: URL) async throws -> Int
    func close() async
}

public protocol EmbeddingProvider: Sendable {
    nonisolated var modelName: String { get }
    nonisolated var dimension: Int { get }

    /// - Postcondition on success: `result.count == texts.count` and
    ///   `result[i]` corresponds to `texts[i]`.
    /// - Throws: on first failure; partial success not exposed.
    func embed(_ texts: [String]) async throws -> [Embedding]
}

public protocol LLMSummarizer: Sendable {
    func summarize(prompt: String) async throws -> String
}
```

**No typed throws on protocol requirements.** Witness matching across
`throws(SomeError)` is brittle in Swift 6 today. Concrete impls still throw
narrow types (`EmbeddingError`, `VectorStoreError`, `LLMError`) — they just
don't declare it on the protocol witness. The engine's `MemSearchError`
provides typed lifting at the *engine* boundary via internal helpers.

**`dimension`/`modelName` are `nonisolated`.** Actor-based conformers store
them in `nonisolated let`s populated at construction. This is the only way to
satisfy a sync protocol requirement from an isolated type.

**`scan` is not `async`.** Construction is synchronous; iteration is the
only thing that can fail. The stream's `Failure` is `any Error` — typed
`Failure` parameter on `AsyncThrowingStream` constructors lands in Swift
6.1; we use the universal form for now.

## Engine

```swift
public struct MemSearch<V: VectorStore, E: EmbeddingProvider>: Sendable {
    public let paths: [URL]
    public let chunkingPolicy: ChunkingPolicy
    package let store: V
    package let embedder: E

    public init(paths: [URL],
                store: V,
                embedder: E,
                chunkingPolicy: ChunkingPolicy = .default)

    // Indexing — synchronous (returns IndexStats) and streaming (yields IndexEvent).
    public func index(force: Bool = false) async throws -> IndexStats
    public func indexStream(force: Bool = false) -> AsyncThrowingStream<IndexEvent, any Error>
    public func indexFile(_ url: URL) async throws -> Int

    public func search(_ query: String,
                       topK: Int = 10,
                       filter: SourceFilter? = nil) async throws -> [SearchHit]

    // Compact: split halves so hosts can preview before committing to disk.
    public func summarize<S: LLMSummarizer>(
        using summarizer: S,
        source: URL? = nil,
        promptTemplate: String? = nil,
        now: Date = Date()
    ) async throws -> CompactedSummary

    public func appendSummary(_ summary: CompactedSummary,
                              to outputDirectory: URL? = nil) async throws -> URL

    // Watcher — throws on init failures (e.g., security-scoped URL invalidation on iOS);
    // per-file failures within the stream emit `.failed(_,_)` events, never tear it down.
    public func watch(debounce: Duration = .milliseconds(250),
                      bufferingPolicy: AsyncStream<IndexEvent>.Continuation.BufferingPolicy = .bufferingNewest(1024))
        throws -> AsyncStream<IndexEvent>
}

public struct CompactedSummary: Sendable {
    public let markdown: String
    public let dateStamp: Date         // captured by `summarize(now:)`; both filename and `# YYYY-MM-DD` header derive from this
    public let chunkCount: Int

    /// "YYYY-MM-DD.md" derived from `dateStamp` in the calendar's default time zone.
    public var proposedFilename: String { ... }
}
```

### Why public methods do NOT use typed throws

Loop-2 review surfaced an irreconcilable conflict: `Task.cancellation` flows
as `Swift.CancellationError` (or as `URLError(.cancelled)` from URLSession,
remapped to `CancellationError` by the engine). `throws(MemSearchError)`
cannot propagate `CancellationError` — the typed-throws channel rejects any
type outside the declared error union. Adding a `MemSearchError.cancelled`
case would break standard `catch is CancellationError` patterns at every host.

**Decision:** the engine's public methods use untyped `throws` (`any Error`).
Internally the engine catches narrow errors (`EmbeddingError`, `VectorStoreError`,
`LLMError`) and lifts them into `MemSearchError` for consumers that want
structured handling. `Swift.CancellationError` flows through unchanged. Hosts
that want typed handling can:

```swift
do { try await mem.index() }
catch is CancellationError { /* user cancelled */ }
catch let e as MemSearchError { /* typed structured error */ }
catch { /* unexpected */ }
```

### `Sendable` conformance

Unconditional. `V: VectorStore` ⇒ `V: Sendable`, `E: EmbeddingProvider` ⇒
`E: Sendable`, all stored properties are `Sendable`, `MemSearch` holds zero
mutable state. Tests assert this invariant. Any future addition of stored
mutable state must move to a referenced `actor`.

### `index()` reducing over `indexStream()`

`index()` is implemented as a `reduce` over `indexStream()` — single source
of truth. `IndexEvent.indexed(URL, added: Int, removed: Int)` and
`.removed(URL, chunkCount: Int)` carry the counts needed to populate every
field of `IndexStats`.

## Indexing pipeline

```
scan ─► chunk ─► diff against store ─► embed ─► upsert
                              │
                              └─► delete stale chunks (per file + per orphaned source)
```

Sequential across files in v1. Per file:

1. `try Task.checkCancellation()`.
2. Read the file as UTF-8.
3. `Chunker.chunk(...)`.
4. Diff `ChunkID`s against `store.chunkIDs(forSource:)`.
5. `let removed = try await store.delete(ids: stale)` (if any).
6. `embedder.embed(...)` — provider batches internally.
7. `let added = try await store.upsert(records)`.
8. Yield `IndexEvent.indexed(url, added: added, removed: removed)` if streaming.

After all files: orphaned sources processed, each emitting
`IndexEvent.removed(url, chunkCount: n)`.

### Cancellation granularity per embedder

| Embedder       | Cancellation point                                                                  |
| -------------- | ----------------------------------------------------------------------------------- |
| HTTP           | Per request — URLSession async honors `Task.cancel()`. The HTTP embedders catch `URLError` with `code == .cancelled` and **directly throw `CancellationError()`** — unconditional translation so callers see `CancellationError` regardless of whether the underlying URLSession cancel came from `Task.cancel()` or another path. Do NOT route through `try Task.checkCancellation()` (that would silently swallow non-Task-driven cancellations). |
| Core ML / ONNX | Between batches — `MLModel.prediction` / `ORTSession.run` don't honor Swift cancellation. `try Task.checkCancellation()` is called between every batch. |

## Search

```swift
public func search(_ query: String, topK: Int, filter: SourceFilter?) async throws -> [SearchHit] {
    let qVec = try await embedder.embed([query])[0]
    let hq = HybridQuery(queryText: query, queryEmbedding: qVec,
                         topK: topK, filter: filter, rrfK: 60)
    return try await store.hybridSearch(hq)
}
```

`MemSearchError` lifting happens internally — the engine catches narrow
errors and lifts them via a private helper before re-throwing as
`MemSearchError` so consumers see structured cases without typed-throws
constraints.

### RRF (Reciprocal Rank Fusion)

`package`-visible helper:

```swift
package enum RRF {
    /// Theoretical max for normalization = numRetrievers / (k + 1).
    package static func fuse(_ rankings: [[ChunkID]],
                             k: Int = 60,
                             topK: Int) -> [(ChunkID, Float)]
}
```

### Backend strategies

| Backend              | Vector path                                       | BM25 path        | Fusion                                                                   |
| -------------------- | ------------------------------------------------- | ---------------- | ------------------------------------------------------------------------ |
| `MemSearchSQLite`    | `sqlite-vec` ANN                                  | `FTS5 bm25()`    | Swift `RRF.fuse` over both ID lists. **Both queries MUST run inside one `pool.read { db in ... }` block** so they see the same snapshot. The `read` closure body is sync — no `await` inside. |
| `MemSearchSwiftData` | Brute-force cosine via `vDSP_dotpr` + `#Predicate` | *(none in v1)*  | No RRF — `score = denseScore = cosine`.                                   |

### `MemSearchSQLite` — `final class : Sendable` wrapping GRDB

```swift
public final class SQLiteVectorStore: VectorStore, Sendable {
    private let pool: DatabasePool      // Sendable in GRDB 7.x
    public nonisolated let dimension: Int

    public init(url: URL, dimension: Int) async throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "SELECT load_extension('vec0')")    // sqlite-vec
        }
        self.pool = try DatabasePool(path: url.path, configuration: config)
        self.dimension = dimension
        try await runMigrations()
    }

    public func hybridSearch(_ q: HybridQuery) async throws -> [SearchHit] {
        try await pool.read { db in
            // Both vector ANN and FTS5 BM25 inside this single sync closure.
            // RRF.fuse merges. No await inside read{}.
            let denseRanking: [ChunkID] = try db.execute(...)       // vec0 KNN
            let bm25Ranking: [ChunkID]  = try db.execute(...)       // FTS5 MATCH + bm25()
            let fused = RRF.fuse([denseRanking, bm25Ranking], k: q.rrfK, topK: q.topK)
            return try fused.map { try makeHit(db: db, $0) }
        }
    }
}
```

GRDB's `DatabasePool` is `Sendable` in 7.x and provides reader concurrency
(parallel readers, single writer). A `final class : Sendable` wrapping it
delivers correct concurrency without an outer actor that would regress to
single-execution.

`Configuration.prepareDatabase` runs once per connection in the pool;
`load_extension('vec0')` is the sqlite-vec API at runtime.

### `MemSearchSwiftData` — manual ModelActor (no `@ModelActor` macro)

The macro generates its own designated `init(modelContainer:)`; adding a
user-written `nonisolated let dimension: Int` storage breaks Swift's
"all stored properties initialized" rule because the macro's init won't
know about the new property. Solution: write the actor manually — it's
~15 lines.

```swift
public actor SwiftDataVectorStore: VectorStore, ModelActor {
    public nonisolated let modelExecutor: any ModelExecutor
    public nonisolated let modelContainer: ModelContainer
    public nonisolated let dimension: Int

    public init(url: URL, dimension: Int) throws {
        let schema = Schema([StoredChunkRecord.self])
        let cfg = ModelConfiguration(schema: schema, url: url)
        let container = try ModelContainer(for: schema, configurations: [cfg])
        let context = ModelContext(container)
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)
        self.modelContainer = container
        self.dimension = dimension
    }
}
```

Note: actor-isolated methods access `modelContext` via the `ModelActor`
default implementation. `Chunk` is the only thing that crosses the actor
boundary (Sendable struct); `PersistentModel` instances stay isolated.

## Embedding providers (v1)

Embedders divide by whether they hold mutable state:

- **HTTP embedders (`OpenAIEmbedder`, `OllamaEmbedder`)** are `final class : Sendable`,
  stateless, use `URLSession.shared`. No actor needed.
- **Compute embedders (`CoreMLEmbedder`, `ONNXEmbedder`)** are `actor`s.
  They hold a model handle and need single-instance request serialization
  for safety; `actor` provides that for free. `MLModel.prediction` /
  `ORTSession.run` are concurrent-safe per Apple/ONNX docs *for the model
  itself*, but our actor isolates any per-request bookkeeping.

`CoreMLEmbedder.init` is **`async throws`** because `Tokenizer.from(modelFolder:)`
in swift-transformers is async. This cascades into the CLI dispatch (every
construction site uses `try await CoreMLEmbedder(...)`).

```swift
public actor CoreMLEmbedder: EmbeddingProvider {
    public nonisolated let modelName: String
    public nonisolated let dimension: Int
    private let model: MLModel
    private let tokenizer: Tokenizer

    public init(modelFolder: URL, modelName: String, dimension: Int) async throws {
        self.tokenizer = try await AutoTokenizer.from(modelFolder: modelFolder)
        self.model = try MLModel(contentsOf: modelFolder.appendingPathComponent("model.mlpackage"))
        self.modelName = modelName
        self.dimension = dimension
    }

    public func embed(_ texts: [String]) async throws -> [Embedding] { ... }
}
```

`URLSession.shared` constraint stays: HTTP embedders use only the async API
(`data(for:)`) on a `Sendable` session; no custom delegate.

| Provider                       | Module                          | Type                       | Notes                                                                        |
| ------------------------------ | ------------------------------- | -------------------------- | ---------------------------------------------------------------------------- |
| `CoreMLEmbedder`               | `MemSearchEmbeddersCoreML`      | `actor`                    | swift-transformers + Core ML. Async init.                                    |
| `OpenAIEmbedder`               | `MemSearchEmbeddersHTTP`        | `final class : Sendable`   | `URLSession.shared`. base_url honored.                                       |
| `OllamaEmbedder`               | `MemSearchEmbeddersHTTP`        | `final class : Sendable`   | `URLSession.shared`. Auto-detects dimension via trial embed in async init.   |
| `ONNXEmbedder`                 | `MemSearchEmbeddersONNX`        | `actor`                    | swift-onnxruntime.                                                           |

### Core ML model lifecycle

- Model location: `Application Support/MemSearch/Models/` with
  `URLResourceKey.isExcludedFromBackupKey = true` set on the directory.
- First-run download: opt-in. The library does **not** auto-download. Hosts
  call `CoreMLEmbedder.preDownload(model:)` from their own onboarding flow.
  Constructing `CoreMLEmbedder` against a missing local model `throw`s
  `EmbeddingError.modelNotFound(...)`.
- Bundled-app path: hosts that ship the model in their app bundle pass
  `Bundle.main.url(forResource:)` directly.

## LLM summarizers (v1)

| Summarizer                     | Min platforms                        | Hardware                             | Type                  |
| ------------------------------ | ------------------------------------ | ------------------------------------ | --------------------- |
| `OpenAICompatibleSummarizer`   | macOS 14, iOS 17, visionOS 1         | Any                                  | `final class : Sendable` |
| `FoundationModelsSummarizer`   | macOS 26, iOS 26, visionOS 26 (watchOS / tvOS unavailable) | Apple Intelligence-capable device | `actor` |

`MLXLocalSummarizer` is planned post-v1.

### `FoundationModelsSummarizer` — correct single-flight

`LanguageModelSession` is a `final class`, not an actor — it does not enforce
mutual exclusion itself; the framework throws
`LanguageModelSession.GenerationError` on overlapping requests. Loop-1's
chained-Task pattern had a reentrancy race. The correct pattern: spawn the
new task **first** with the prior in its closure, then assign to `inFlight`
*synchronously* on the actor between awaits. `LanguageModelSession` is not
declared `Sendable`; we keep `respond(to:)` invocation inside an
actor-isolated method and capture `[weak self]` instead of `[session]`.

```swift
@available(macOS 26, iOS 26, visionOS 26, *)
@available(watchOS, unavailable)
@available(tvOS, unavailable)
public actor FoundationModelsSummarizer: LLMSummarizer {
    private let session: LanguageModelSession
    private var inFlight: Task<String, Error>?

    public init?(instructions: String) {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        self.session = LanguageModelSession(instructions: instructions)
    }

    public func summarize(prompt: String) async throws -> String {
        let prior = inFlight
        let task = Task<String, Error> { [weak self] in
            if let prior { _ = try? await prior.value }
            guard let self else { throw CancellationError() }
            return try await self.callRespond(prompt)
        }
        inFlight = task                    // synchronous on actor — no reentrancy window
        defer { if inFlight === task { inFlight = nil } }
        return try await task.value
    }

    private func callRespond(_ prompt: String) async throws -> String {
        do { return try await session.respond(to: prompt).content }
        catch let e as LanguageModelSession.GenerationError {
            throw mapGenerationError(e)
        }
    }
}
```

### `LLMError` and the `GenerationError` mapping

```swift
public enum LLMError: Error, Sendable {
    case unavailable
    case authenticationFailed
    case rateLimited(retryAfter: Duration?)
    case contextWindowExceeded
    case unsupportedLocale
    case networkFailure(any Error & Sendable)
    case invalidResponse
    case modelFailure(any Error & Sendable)
    /// Receiving this case in production indicates a bug in `FoundationModelsSummarizer`'s
    /// single-flight guard. The actor's `inFlight: Task<String, Error>?` chain is
    /// supposed to prevent this from ever surfacing; tests `#expect` zero occurrences.
    case singleFlightViolation(any Error & Sendable)
}
```

### Mapping tables

`LanguageModelSession` exposes **two** error enums; both must be caught:

| `LanguageModelSession.GenerationError`           | `LLMError`                |
| ------------------------------------------------ | ------------------------- |
| `.exceededContextWindowSize(_)`                  | `.contextWindowExceeded`  |
| `.unsupportedLanguageOrLocale(_)`                | `.unsupportedLocale`      |
| `.rateLimited(_)`                                | `.rateLimited(...)`        |
| (everything else)                                | `.modelFailure(...)`        |

| `LanguageModelSession.Error`                     | `LLMError`                  |
| ------------------------------------------------ | --------------------------- |
| `.concurrentRequests`                            | `.singleFlightViolation(_)` |
| (other cases)                                    | `.modelFailure(...)`        |

`callRespond` should have **two catch clauses** (`catch let e as LanguageModelSession.GenerationError` and `catch let e as LanguageModelSession.Error`) so neither enum slips into a generic `catch` and loses its type information.

## File watcher

Two layers:

- **Internal `FileWatcher` actor** wraps platform primitives.
  - macOS: `FSEventStreamCreate` with flags
    `kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer`.
    `kFSEventStreamCreateFlagFileEvents` enables per-file granularity (without
    it you only get directory-level events). `kFSEventStreamCreateFlagNoDefer`
    delivers events with minimum latency. Recursion is path-based — no
    "recursive flag"; each watched path is recursed by default.
  - iOS / visionOS: `DispatchSource.makeFileSystemObjectSource` per registered
    file descriptor. **Recursive directory watching does not exist** on
    iOS-style sandboxes — only registered paths are watched. Hosts re-run
    `index()` manually when paths change.
- **Public `MemSearch.watch()`** subscribes, debounces, drives indexing,
  yields `AsyncStream<IndexEvent>` (non-throwing).

`watch()` is **`throws`** because watcher initialization can fail on iOS:
security-scoped URLs may have been invalidated, `open(2)` on a registered
path may return `-1`. `fatalError` is unsafe given the documented contract
that hosts manage `startAccessingSecurityScopedResource`.

`onTermination` bridging:

```swift
let (stream, cont) = AsyncStream.makeStream(of: IndexEvent.self,
                                            bufferingPolicy: bufferingPolicy)
let watcher = FileWatcher(paths: paths)
cont.onTermination = { [weak watcher] _ in
    Task { await watcher?.stop() }    // [weak watcher] avoids the retain cycle
}
try await watcher.start()              // throws if init fails
return stream
```

`[weak watcher]` capture breaks the cycle (`stream → cont → onTermination →
watcher → cont`). If the host drops the stream without iterating, the
watcher is deallocated and the `Task` no-ops. `FileWatcher.stop()` is
idempotent so the brief race between `onTermination` firing and a final
platform callback is harmless.

**FSEvents → actor delivery:** the FSEvents callback runs on a dispatch
queue. Inside the callback, events go through an `AsyncStream.makeStream`
continuation `yield(_:)` — synchronous, `Sendable`, ordering preserved by
the stream buffer. The actor consumes via `for await event in rawEvents`.
We never spawn one Task per event.

**Multi-subscriber semantics:** each call to `mem.watch()` constructs a
*new* `FileWatcher`. Hosts wanting broadcast share via their own
multiplexer. Guidance: call `watch()` once at app scope, never inside
SwiftUI `body`.

**Backgrounding:** the watcher cannot run while the app is backgrounded.
Hosts handle `BGAppRefreshTask` and re-run `index()` on next foreground.

## Compact (LLM summarization) — split into two halves

```swift
extension MemSearch {
    /// Generate the markdown summary in memory. No I/O.
    /// `now` (default `Date()`) is captured into `CompactedSummary.dateStamp`,
    /// which becomes the source of truth for both filename and `# YYYY-MM-DD` header.
    public func summarize<S: LLMSummarizer>(
        using summarizer: S,
        source: URL? = nil,
        promptTemplate: String? = nil,
        now: Date = Date()
    ) async throws -> CompactedSummary

    /// Persist a previously-generated summary atomically and re-index it.
    /// File path = `(outputDirectory ?? paths[0]) / memory / summary.proposedFilename`.
    /// `# YYYY-MM-DD` header is written from `summary.dateStamp` (NOT wall clock).
    public func appendSummary(_ summary: CompactedSummary,
                              to outputDirectory: URL? = nil) async throws -> URL
}
```

Pipeline:

1. `store.scan(filter:)` → `AsyncThrowingStream<Chunk, any Error>`.
2. Collect content into the prompt template (`{chunks}` placeholder).
3. `summarizer.summarize(prompt:)` → markdown.
4. Build `CompactedSummary(markdown:, dateStamp: now, chunkCount:)`.
5. (Caller decides:) `appendSummary(_:to:)` writes via temp file + rename
   (atomic), prepending `# YYYY-MM-DD` if file is fresh, then re-indexes
   the file.

**Why `dateStamp` is captured in `summarize`:** prevents drift if the host
calls `appendSummary` across midnight. Filename and header are derived from
the same instant; never from the wall clock at append time.

**Security-scoped URLs (iOS):** if `outputDirectory` is from
`UIDocumentPicker`, the *host* is responsible for the
`startAccessingSecurityScopedResource` brackets around the call.

## CLI (separate package)

`MemSearch-CLI`'s `memsearch` executable.

```
memsearch <subcommand> [options]

  index                Scan paths and index. Streams progress.
  search <query>       Hybrid search; --json for plugin output
  expand <chunk-id>    Print full chunk by ID
  compact              Run LLM summarization, append to memory log
  watch                Run file watcher, auto-index on changes
  info                 Show store stats
```

### Concrete-type dispatch

`(MemSearch<some VectorStore, some EmbeddingProvider>) -> R` is illegal per
SE-0341 (opaque types in consuming positions of function-typed parameters).
Replaced by per-case helpers:

```swift
extension Search {
    func run() async throws {
        let cfg = try common.resolve()
        switch (cfg.store.backend, cfg.embedder.provider) {
        case (.sqlite, .openai):
            let mem = MemSearch(paths: cfg.paths,
                                store: try await SQLiteVectorStore(...),
                                embedder: OpenAIEmbedder(...))
            try await runSearch(on: mem, query: query, topK: topK, json: json)
        case (.sqlite, .coreML):
            let mem = MemSearch(paths: cfg.paths,
                                store: try await SQLiteVectorStore(...),
                                embedder: try await CoreMLEmbedder(...))
            try await runSearch(on: mem, query: query, topK: topK, json: json)
        // 8 total branches (2 stores × 4 embedders)
        }
    }
}

private func runSearch<V: VectorStore, E: EmbeddingProvider>(
    on mem: MemSearch<V, E>, query: String, topK: Int, json: Bool
) async throws { /* fully specialized per call */ }
```

**Compact has 16 branches** (2 stores × 4 embedders × 2 summarizers — and
`FoundationModelsSummarizer` arms must sit inside `#available` checks). At
the implementation point this fan-out should be a `@CLISubcommand` macro
emitting the cartesian product, not hand-written.

### JSON output (search)

```json
{
  "hits": [
    {
      "chunk_id": "abc123…",
      "source": "/abs/path/notes/2026-05-19.md",
      "heading": "MemSearch design",
      "score": 0.85,
      "dense_score": 0.71,
      "bm25_score": 0.32,
      "start_line": 10,
      "end_line": 25,
      "content": "…"
    }
  ]
}
```

## Configuration

### Programmatic (first-class on iOS / visionOS)

iOS hosts have no shell, no `~/.config`, no `cwd`, no env vars relevant to
API keys. They construct everything directly; API keys come from the Keychain.

```swift
let store = try await SQLiteVectorStore(url: containerURL(), dimension: 1024)
let embedder = OpenAIEmbedder(apiKey: keychainValue, baseURL: ...)
let mem = MemSearch(paths: [notesURL], store: store, embedder: embedder)
```

### TOML (CLI / macOS)

Layered: built-in defaults → `~/.config/memsearch/config.toml` →
`./.memsearch.toml` (cwd) → CLI flags.

```toml
paths = ["~/Documents/notes"]

[store]
backend = "sqlite"                              # sqlite | swiftdata
path    = "~/Library/Application Support/MemSearch/memory.db"

[embedder]
provider   = "coreml"                           # coreml | openai | ollama | onnx
model      = "BGE-M3"

[llm]
provider = "foundation-models"                  # foundation-models | openai-compat
model    = "gpt-4o-mini"
base_url = "https://api.openai.com/v1"
api_key  = "${OPENAI_API_KEY}"

[chunking]
max_chunk_size = 1500
overlap_lines  = 2
```

**Env-var resolution semantics:**

- `${VAR}` resolves to `VAR`'s value. Unset → throws
  `MemSearchError.configurationInvalid("environment variable VAR not set")`.
- `${VAR:-default}` resolves to `VAR` or the default if unset.
- Literal `$` escaped as `$$`.

## Concurrency posture

| Component                                           | Type                          | Why                                                                     |
| --------------------------------------------------- | ----------------------------- | ----------------------------------------------------------------------- |
| `MemSearch<V, E>`                                   | `Sendable` struct             | Zero stored mutable state; isolation via `V`/`E`.                       |
| `SQLiteVectorStore`                                 | `final class : Sendable`      | GRDB `DatabasePool` is `Sendable` and provides reader concurrency.      |
| `SwiftDataVectorStore`                              | `actor` (manual `ModelActor`) | `ModelContext` non-`Sendable`; macro can't coexist with extra `let` storage. |
| `CoreMLEmbedder` / `ONNXEmbedder`                   | `actor`                       | Hold a model handle + may serialize per-request bookkeeping.            |
| `OpenAIEmbedder` / `OllamaEmbedder`                 | `final class : Sendable`      | URLSession.shared only; no mutable state.                                |
| `OpenAICompatibleSummarizer`                        | `final class : Sendable`      | URLSession.shared only.                                                  |
| `FoundationModelsSummarizer`                        | `actor` + `inFlight Task`     | Framework single-in-flight; chained via stored task with correct ordering. |
| `FileWatcher`                                       | `actor`                       | Wraps FSEvents / DispatchSource callbacks; `stop()` idempotent.         |

`@unchecked Sendable` is forbidden. `nonisolated(unsafe)` is forbidden.
`@TaskLocal` is reserved for tracing in v2.

### Cancellation

- `try Task.checkCancellation()` between files in `index()` /
  `indexStream()` and between embedding batches.
- HTTP embedders: URLSession async honors task cancellation; the embedder
  catches `URLError(.cancelled)` and re-throws via `try Task.checkCancellation()`
  so the surfaced error is `Swift.CancellationError`, not a network failure.
- Core ML / ONNX: per-batch cancellation only.
- `mem.watch()` stream: `onTermination` calls `await watcher.stop()` via an
  unstructured `Task` hop with `[weak watcher]` capture. `stop()` idempotent.
- **`Swift.CancellationError` flows through public methods unchanged.**
  Hosts catch it directly. Public methods do *not* use typed throws
  precisely so cancellation can propagate.
- Partial state on cancellation: per-file upserts are atomic (one
  transaction per file). Cancelling mid-run leaves consistent partial state;
  `index(force: false)` resumes idempotently via the diff.

## Error handling

```swift
public enum MemSearchError: Error, Sendable {
    case embedding(EmbeddingError)
    case store(VectorStoreError)
    case llm(LLMError)
    case scan(URL, any Error & Sendable)
    case chunking(URL, any Error & Sendable)
    case configurationInvalid(String)
    case noSummarizerConfigured
    /// Surface declared in an earlier phase, implementation arrives in a later phase.
    /// String identifies the missing capability and the phase that adds it.
    case unimplemented(String)
}

public enum EmbeddingError: Error, Sendable {
    case authenticationFailed
    case rateLimited(retryAfter: Duration?)
    case dimensionMismatch(expected: Int, got: Int)
    case modelNotFound(String)
    case networkFailure(any Error & Sendable)
    case decodingFailed(any Error & Sendable)
}

public enum VectorStoreError: Error, Sendable {
    case connectionFailed(any Error & Sendable)
    case schemaIncompatible(reason: String)
    case dimensionMismatch(expected: Int, got: Int)
    case backendError(any Error & Sendable)
}
```

`any Error & Sendable` payloads preserve the underlying cause structurally
without committing to a concrete type. Pattern-matching on the underlying
error works (`if case .embedding(.networkFailure(let e as URLError))`).

**`LocalizedError` conformance** is provided on every public error so
SwiftUI's `.alert(isPresented:)` shows readable messages out of the box.
v1 ships English-only `errorDescription`; localization via String Catalog
is a v2 add.

**No silent empties.** If a query errors, the API throws.

## Testing

Swift Testing (`@Test`, `#expect`, `#require`) — not XCTest, except a possible
performance ring-fence.

| Test target                        | Covers                                                                       |
| ---------------------------------- | ---------------------------------------------------------------------------- |
| `MemSearchTests`                   | Core types, chunker, RRF math, ChunkID stability, config layering, MemSearch orchestration with mocks, error mapping, `Sendable` invariant, cancellation surface |
| `MemSearchSQLiteTests`             | Store CRUD, hybrid search end-to-end (single-tx), schema migration            |
| `MemSearchSwiftDataTests`          | Store CRUD, Accelerate cosine correctness, manual ModelActor isolation        |
| `MemSearchEmbeddersCoreMLTests`    | Async model load, batch correctness, dimension precondition                   |
| `MemSearchEmbeddersONNXTests`      | Same as Core ML                                                              |
| `MemSearchEmbeddersHTTPTests`      | Mock URLSession; OpenAI / Ollama protocol parsing, base_url override, URLError(.cancelled) → CancellationError |
| `MemSearch-CLITests` *(separate package)* | Subcommand parsing, config resolution, JSON output stability             |

### `package`-visible mocks (live in `MemSearch`)

Mocks support **content-keyed** failure injection (deterministic across
concurrent callers) — not ordinal-keyed.

```swift
package final class MockEmbeddingProvider: EmbeddingProvider {
    package nonisolated let modelName: String = "mock"
    package nonisolated let dimension: Int

    private let lock = OSAllocatedUnfairLock<State>(initialState: .init())
    package struct State { var injectedFailures: [String: EmbeddingError] = [:] }

    package init(dimension: Int = 8, injectedFailures: [String: EmbeddingError] = [:]) {
        self.dimension = dimension
        lock.withLock { $0.injectedFailures = injectedFailures }
    }

    package func embed(_ texts: [String]) async throws -> [Embedding] {
        // Failure keyed on text content — deterministic regardless of arrival order.
        let failures = lock.withLock { $0.injectedFailures }
        if let first = texts.first, let injected = failures[first] {
            throw injected
        }
        return try texts.map { try Embedding(values: hashToFloats($0, dim: dimension), expectedDimension: dimension) }
    }
}

package actor MockVectorStore: VectorStore { ... }
package struct MockSummarizer: LLMSummarizer { ... }
```

### Negative-path coverage requirement

One test per `MemSearchError` constructor proves the underlying cause is
preserved structurally through the engine boundary — including `Duration?`
retry-after, `dimensionMismatch(expected:got:)` scalars, and URL identity
in `scan` / `chunking` cases. Plus: cancellation tests that
`URLError(.cancelled)` from HTTP embedders surfaces as `CancellationError`,
not as `MemSearchError.embedding(.networkFailure(...))`.

### Determinism

ChunkID computation, chunker output, RRF scoring are pure — golden values.

**No timing-based assertions.** Watcher tests use `confirmation` over a temp
directory. **Mocks may use `Task.sleep` to provide latency** that lets
cancellation land at a known suspension point — the assertion remains
`await #expect(throws: CancellationError.self) { try await task.value }`,
not a `Task.sleep`-followed-by-deadline check. The mock sleeps; the test
asserts behavior. Concretely, `MockEmbeddingProvider` exposes
`latencyPerBatch: Duration?` so cancellation tests have a documented surface.

All test targets compile under `swiftLanguageModes: [.v6]`.

## Apple platform notes

### iOS / visionOS sandbox

- File watcher best-effort. `DispatchSource.makeFileSystemObjectSource`
  per registered fd; no recursive directory watching. `mem.watch()` is
  `throws` because the host's security-scoped URLs can be invalidated.
- `BGAppRefreshTask` scheduling is the host's responsibility.
- Security-scoped URLs (from `UIDocumentPicker`): host is responsible for
  `startAccessingSecurityScopedResource` brackets.

### Manual `ModelActor` for `SwiftDataVectorStore`

The `@ModelActor` macro generates its own `init(modelContainer:)` and
cannot coexist with user-added `nonisolated let` storage (Swift's "all
stored properties initialized" rule rejects it). We declare
`modelExecutor`, `modelContainer`, and `dimension` manually — the actor +
`ModelActor` conformance yield the same isolation semantics as the macro.

### Core ML model lifecycle

Opt-in download via `preDownload(model:)`. Models live in
`Application Support/MemSearch/Models/` with `isExcludedFromBackupKey = true`.
`CoreMLEmbedder.init` is `async throws`.

## SwiftUI integration (host pattern)

> **v1 status:** macOS-validated. iOS hosts can compile this pattern in v1,
> but iOS-runtime behavior — particularly the watcher path (`mem.watch()`),
> security-scoped URL handling around `mem.paths` and `appendSummary`'s
> `outputDirectory`, and backgrounding interactions — is **deferred to v2**.
> Expect to discover and report iOS-runtime issues. See the phasing doc's
> "Deferred to v2" and "v2 iOS validation backlog" sections.

Not part of the library; documented here so every host doesn't rediscover.

```swift
// In your app:
typealias AppMem = MemSearch<SQLiteVectorStore, OpenAIEmbedder>

@Observable @MainActor
final class MemModel {
    let mem: AppMem
    var indexState: IndexState = .idle
    var lastResults: [SearchHit] = []

    enum IndexState { case idle, indexing(added: Int, removed: Int), completed(IndexStats), failed(Error) }

    init(mem: AppMem) { self.mem = mem }

    func search(_ q: String) async {
        do { lastResults = try await mem.search(q) }
        catch is CancellationError { /* user-cancelled — quiet */ }
        catch { /* present error */ }
    }

    func startIndex() async {
        indexState = .indexing(added: 0, removed: 0)
        do {
            var added = 0, removed = 0
            for try await event in mem.indexStream() {
                switch event {
                case .indexed(_, let a, let r):  added += a; removed += r
                case .removed(_, let n):          removed += n
                case .failed: break
                }
                indexState = .indexing(added: added, removed: removed)
            }
            indexState = .completed(IndexStats(...))
        } catch is CancellationError {
            indexState = .idle
        } catch {
            indexState = .failed(error)
        }
    }
}
```

Watcher: subscribe at app scope, never inside SwiftUI `body`:

```swift
@main struct MyApp: App {
    @State private var memModel: MemModel = ...

    var body: some Scene {
        WindowGroup { RootView().environment(memModel) }
            .task {
                guard let stream = try? memModel.mem.watch() else { return }
                for await event in stream { /* apply to memModel */ }
            }
    }
}
```

## Open questions

None blocking. Items deferred to implementation:

- swift-toml vs swift-tomlkit — pick the one with cleaner Swift 6 Sendable
  conformances at impl time.
- sqlite-vec distribution — SPM binary target if available; otherwise
  prebuilt static lib via `linkerSettings`.
- Default Core ML embedding model identifier — see Risks (BGE-M3 fallback).
- 16-branch CLI compact dispatch — hand-written vs `@CLISubcommand` macro.
- `AsyncThrowingStream<_, Failure>` typed Failure — narrow streams when
  Swift 6.1 is the toolchain floor.
