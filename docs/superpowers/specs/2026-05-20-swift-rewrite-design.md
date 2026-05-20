# MemSearch Swift 6 Rewrite — Design

**Status:** draft (post-brainstorm, post-adversarial-review-loop-1)
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

## Non-goals

- Linux compatibility. macOS + iOS family only.
- Python interop.
- Wire-compatibility with Python `memsearch`'s on-disk format.
- Third-party out-of-package backend extensibility. The `package` access level
  is the boundary; external backends must vendor or fork.

## Platforms

- macOS 14+
- iOS 17+
- visionOS 1+

`FoundationModelsSummarizer` requires macOS 26 / iOS 26 / visionOS 26 and an
Apple Intelligence-capable device — gated behind `@available`.

The file watcher is best-effort on iOS / visionOS — see "Apple platform
notes".

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
  ├── MemSearchSwiftData           library  (SwiftData store with Accelerate cosine)
  ├── MemSearchEmbeddersCoreML     library  (swift-transformers + Core ML)
  ├── MemSearchEmbeddersONNX       library  (swift-onnxruntime)
  └── MemSearchEmbeddersHTTP       library  (OpenAI-compatible + Ollama; URLSession only)

Package: MemSearch-CLI (executable package; depends on MemSearch package)
  └── memsearch                    executable  (swift-argument-parser CLI)
```

The library package has zero dependency on `swift-argument-parser` or
`swift-toml`. iOS / visionOS hosts integrating only the library don't pay for
CLI-only dependencies.

The library is pluggable: a host depending on `MemSearch + MemSearchSQLite +
MemSearchEmbeddersHTTP` skips swift-transformers, ONNX runtime, SwiftData, and
the CLI deps entirely.

### External dependencies (library package)

| Module                          | Dependencies                                  |
| ------------------------------- | --------------------------------------------- |
| `MemSearch`                     | (none beyond Foundation)                      |
| `MemSearchSQLite`               | GRDB.swift 7.x, sqlite-vec                    |
| `MemSearchSwiftData`            | (system: SwiftData, Accelerate)               |
| `MemSearchEmbeddersCoreML`      | swift-transformers (system: CoreML)           |
| `MemSearchEmbeddersONNX`        | swift-onnxruntime                             |
| `MemSearchEmbeddersHTTP`        | (system: URLSession)                          |

CLI package adds: swift-argument-parser, swift-toml.

### Module access

`public` is reserved for the curated external API surface — protocols, the
`MemSearch` engine type's *constructor* and *methods*, result/error types, and
each concrete embedder/store/summarizer's constructor + relevant config.

Engine-internal references (`store`, `embedder`) are `package`-visible only.
RRF helpers, mocks, and watcher internals are `package`. Cross-module
internals across our own libraries use `package` access — sufficient because
all our libraries live in the same SPM package.

## Core types

All public types are `Sendable` value types. `Embedding` validates its
dimension at construction.

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
// NOTE: not Hashable — [Float] hashing has NaN reflexivity hazards and big
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

/// Per-file engine outcome streamed by `MemSearch.indexStream(...)` and `MemSearch.watch()`.
public enum IndexEvent: Sendable {
    case indexed(URL, chunkCount: Int)
    case removed(URL)
    case failed(URL, IndexFileError)   // narrower than MemSearchError
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

Split per role so a future read-only/remote backend isn't forced to
no-op writes.

```swift
public protocol VectorIndex: Sendable {
    /// Synchronous, nonisolated — backends store the value at construction.
    nonisolated var dimension: Int { get }

    func hybridSearch(_ query: HybridQuery) async throws -> [SearchHit]
}

public protocol VectorMutator: VectorIndex {
    func upsert(_ records: [StoredChunk]) async throws -> Int
    func delete(ids: [ChunkID]) async throws -> Int
    func delete(source: URL) async throws -> Int
    func close() async
}

public protocol VectorIntrospection: VectorIndex {
    func indexedSources() async throws -> Set<URL>
    func chunkIDs(forSource: URL) async throws -> Set<ChunkID>
    /// Stream every chunk matching the optional filter. Stream's Failure is
    /// `VectorStoreError`. Iteration on `AsyncThrowingStream<Chunk, VectorStoreError>`
    /// is Sendable-clean (Chunk is Sendable).
    func scan(filter: SourceFilter?) -> AsyncThrowingStream<Chunk, VectorStoreError>
}

/// Convenience composite — what the engine actually requires.
public typealias VectorStore = VectorMutator & VectorIntrospection

public protocol EmbeddingProvider: Sendable {
    /// Synchronous, nonisolated — providers store both at construction (model load is sync).
    nonisolated var modelName: String { get }
    nonisolated var dimension: Int { get }

    /// - Postcondition on success: `result.count == texts.count` and
    ///   `result[i]` corresponds to `texts[i]`.
    /// - Throws: on first failure; partial success is not exposed.
    func embed(_ texts: [String]) async throws -> [Embedding]
}

public protocol LLMSummarizer: Sendable {
    func summarize(prompt: String) async throws -> String
}
```

**Why typed throws are absent from these protocol requirements:**
witness matching across `throws(SomeError)` and `throws(any Error)` is brittle
in Swift 6 today, and our error model already provides typed errors at the
*engine* boundary via `MemSearchError`. Concrete impls still throw narrow
types (`EmbeddingError`, `VectorStoreError`, `LLMError`) — they just don't
declare it on the protocol witness.

**Why `dimension` and `modelName` are `nonisolated`:**
actor-based conformers store `dimension` in a `nonisolated let` populated at
construction. This is the only way to satisfy a sync protocol requirement
from an isolated type. Embedders load their model synchronously in `init`
(`MLModel(contentsOf:)` is sync; only `prediction(...)` is async) so they
don't need to be actors at all (see "Embedding providers" below).

**Why `scan` is not `async throws` — just returns `AsyncThrowingStream`:**
construction is synchronous; iteration is the only thing that can fail.

## Engine

`MemSearch` is generic over the store and embedder — no existential boxing in
the hot path. Generics are concrete; `store` and `embedder` are `package`-
visible (engine-internal references; not part of the external API).

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

    // Indexing — both synchronous (returns IndexStats) and streaming (yields IndexEvent).
    public func index(force: Bool = false) async throws(MemSearchError) -> IndexStats
    public func indexStream(force: Bool = false) -> AsyncThrowingStream<IndexEvent, MemSearchError>
    public func indexFile(_ url: URL) async throws(MemSearchError) -> Int

    // Search.
    public func search(_ query: String,
                       topK: Int = 10,
                       filter: SourceFilter? = nil) async throws(MemSearchError) -> [SearchHit]

    // Compact: two halves so hosts can preview before committing to disk.
    public func summarize<S: LLMSummarizer>(
        using summarizer: S,
        source: URL? = nil,
        promptTemplate: String? = nil
    ) async throws(MemSearchError) -> CompactedSummary

    public func appendSummary(_ summary: CompactedSummary,
                              to outputDirectory: URL? = nil) async throws(MemSearchError) -> URL

    // Watcher — non-throwing stream; per-file failures emit `.failed(_,_)`.
    public func watch(debounce: Duration = .milliseconds(250),
                      bufferingPolicy: AsyncStream<IndexEvent>.Continuation.BufferingPolicy = .bufferingNewest(1024))
        -> AsyncStream<IndexEvent>
}

public struct CompactedSummary: Sendable {
    public let markdown: String
    public let proposedFilename: String   // "YYYY-MM-DD.md"
    public let chunkCount: Int
}
```

**Sendable conformance** is unconditional — `V` and `E` are constrained
`Sendable`, all stored properties are `Sendable`, and `MemSearch` holds zero
mutable state. Any future addition of stored mutable state would break
unconditional `Sendable`; tests assert this invariant.

**`index()` vs `indexStream()`:** the synchronous form is a convenience for
batch CLI use; the streaming form is what UI hosts wire to a `ProgressView`.
`index()` reduces over `indexStream()` internally — single source of truth.

## Indexing pipeline

```
scan ─► chunk ─► diff against store ─► embed ─► upsert
                              │
                              └─► delete stale chunks (per file + per orphaned source)
```

Sequential across files in v1. Per file:

1. `Task.checkCancellation()`.
2. Read the file as UTF-8.
3. `Chunker.chunk(...)`.
4. Diff `ChunkID`s against `store.chunkIDs(forSource:)`.
5. Delete stale IDs.
6. `embedder.embed(...)` — provider batches internally; engine doesn't see batch size.
7. `store.upsert(...)`.
8. Yield `IndexEvent.indexed(url, chunkCount:)` if streaming.

**Cancellation granularity per embedder:**

| Embedder       | Cancellation point                                                  |
| -------------- | ------------------------------------------------------------------- |
| HTTP           | Per request — URLSession async honors `Task.cancel()`.               |
| Core ML / ONNX | Between batches — `MLModel.prediction` / `ORTSession.run` don't honor Swift cancellation. Document; emit `Task.checkCancellation()` between every batch. |

After all files: `store.indexedSources()` minus the active set → orphaned
sources to delete.

`Chunker` is an `enum` namespace of pure functions. Implementation matches the
Python heading-based splitter.

## Search

```swift
public func search(_ query: String, topK: Int, filter: SourceFilter?) async throws(MemSearchError) -> [SearchHit] {
    let qVec = try mapEmbedding { try await embedder.embed([query])[0] }
    let hq = HybridQuery(queryText: query, queryEmbedding: qVec,
                         topK: topK, filter: filter, rrfK: 60)
    return try mapStore { try await store.hybridSearch(hq) }
}
```

`mapEmbedding`/`mapStore` are package helpers that catch the concrete error
types from each protocol impl and lift them into `MemSearchError`.

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
| `MemSearchSQLite`    | `sqlite-vec` ANN                                  | `FTS5 bm25()`    | Swift `RRF.fuse` over both ID lists. **Both queries MUST run inside one `pool.read { db in ... }` block** so they see the same snapshot. |
| `MemSearchSwiftData` | Brute-force cosine via `vDSP_dotpr` + `#Predicate` | *(none in v1)*  | No RRF — `score = denseScore = cosine`. RRF over a single ranking would only re-rank by position; misleading. |

### `MemSearchSQLite` as `final class : Sendable`

```swift
public final class SQLiteVectorStore: VectorStore, Sendable {
    private let pool: DatabasePool      // Sendable in GRDB 7.x
    public nonisolated let dimension: Int

    public init(url: URL, dimension: Int) async throws { ... }

    public func hybridSearch(_ q: HybridQuery) async throws -> [SearchHit] {
        try await pool.read { db in
            // Both vector ANN and FTS5 BM25 inside this single closure.
            // RRF.fuse merges. No await happens inside read{}.
            ...
        }
    }
    ...
}
```

**Why class, not actor:** GRDB's `DatabasePool` is itself `Sendable` and
provides reader concurrency (multiple parallel readers, single writer).
Wrapping it in an `actor` would serialize everything to one executor,
*regressing* GRDB's concurrency story. A `final class : Sendable` with
`Sendable` storage delivers correct concurrency without a custom isolation
boundary.

## Embedding providers (v1)

All four embedders are **`final class : Sendable`** with `nonisolated let
dimension: Int` set in `init`. Model loading is synchronous (`MLModel(contentsOf:)`,
`Tokenizer.from(...)`, `ORTSession(...)` are all sync); only inference is async.
That removes the protocol/actor `dimension` impedance mismatch entirely.

Concurrency control happens via stored `OSAllocatedUnfairLock` or a single
serial `DispatchQueue` where the underlying model isn't safe for parallel
calls — those are implementation details, not part of the type's Sendable
contract.

| Provider                       | Module                          | Notes                                                                           |
| ------------------------------ | ------------------------------- | ------------------------------------------------------------------------------- |
| `CoreMLEmbedder`               | `MemSearchEmbeddersCoreML`      | Default. swift-transformers + Core ML. Model loaded sync in `init` from a `URL`. |
| `OpenAIEmbedder`               | `MemSearchEmbeddersHTTP`        | `URLSession.shared` only — no custom delegates. base_url honored for OpenAI-compatible servers. |
| `OllamaEmbedder`               | `MemSearchEmbeddersHTTP`        | Same constraint. Auto-detects dimension via trial embed in `init`.               |
| `ONNXEmbedder`                 | `MemSearchEmbeddersONNX`        | swift-onnxruntime. Same model files as the Python `onnx` provider.               |

**`URLSession.shared` constraint** (HTTP embedders + summarizer): claiming
`Sendable` requires us to use only the async API on a `Sendable` session.
Custom `URLSession(configuration:delegate:delegateQueue:)` is forbidden in v1
because `URLSessionDelegate` is `@objc` and not `Sendable`-clean. If a future
v2 needs streaming or auth-redirect handling, those types switch to `actor`.

### Core ML model lifecycle

- Model location: `Application Support/MemSearch/Models/` with
  `URLResourceKey.isExcludedFromBackupKey = true` set on the directory.
- First-run download: opt-in. The library does **not** auto-download. Hosts
  call `CoreMLEmbedder.preDownload(model:)` from their own onboarding flow
  (so they can show their own UI). Constructing `CoreMLEmbedder` against a
  missing local model `throw`s `EmbeddingError.modelNotFound(...)`.
- Bundled-app path: hosts that ship the model in their app bundle pass
  `Bundle.main.url(forResource:)` directly.
- Reasoning: a 500 MB silent download on first call is an iOS App Store
  review red flag and a poor UX.

## LLM summarizers (v1)

| Summarizer                     | Min platforms                  | Hardware                             | Type                  |
| ------------------------------ | ------------------------------ | ------------------------------------ | --------------------- |
| `OpenAICompatibleSummarizer`   | macOS 14, iOS 17, visionOS 1   | Any                                  | `final class : Sendable` |
| `FoundationModelsSummarizer`   | macOS 26, iOS 26, visionOS 26  | Apple Intelligence-capable device    | `actor`               |

`MLXLocalSummarizer` is planned post-v1.

### `FoundationModelsSummarizer` — explicit single-flight

Actor isolation is **not** sufficient — actors are reentrant, so two awaits
into `session.respond(...)` from different callers would race. We pin the
in-flight work in a stored `Task` that subsequent calls await:

```swift
@available(macOS 26, iOS 26, visionOS 26, *)
public actor FoundationModelsSummarizer: LLMSummarizer {
    private let session: LanguageModelSession
    private var inFlight: Task<String, Error>?

    public init?(instructions: String) {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        self.session = LanguageModelSession(instructions: instructions)
    }

    public func summarize(prompt: String) async throws -> String {
        // Wait for prior request to complete (chained single-flight).
        if let prior = inFlight { _ = try? await prior.value }

        let task = Task<String, Error> { [session] in
            try await session.respond(to: prompt).content
        }
        inFlight = task
        defer { if inFlight === task { inFlight = nil } }
        return try await task.value
    }
}
```

This pattern is the canonical answer to "the framework requires single
in-flight; how do I express that in Swift 6?" — chain via a stored task,
don't rely on actor mailbox reentrancy semantics.

### `LLMError` — symmetric with `EmbeddingError.rateLimited`

```swift
public enum LLMError: Error, Sendable {
    case unavailable
    case authenticationFailed
    case rateLimited(retryAfter: Duration?)   // mirrors EmbeddingError
    case contextWindowExceeded
    case unsupportedLocale
    case networkFailure(any Error & Sendable)
    case invalidResponse
    case modelFailure(any Error & Sendable)
}
```

## File watcher

Two layers:

- **Internal `FileWatcher` actor** wraps platform primitives.
  - macOS: `FSEventStreamCreate` recursive.
  - iOS / visionOS: `DispatchSource.makeFileSystemObjectSource` per registered
    file descriptor. **Recursive directory watching does not exist** on
    iOS-style sandboxes — only registered paths are watched. Documented
    limitation.
- **Public `MemSearch.watch()`** subscribes to `FileWatcher`, debounces,
  drives indexing, yields `AsyncStream<IndexEvent>` (non-throwing).

```swift
extension MemSearch {
    public func watch(debounce: Duration = .milliseconds(250),
                      bufferingPolicy: AsyncStream<IndexEvent>.Continuation.BufferingPolicy = .bufferingNewest(1024))
        -> AsyncStream<IndexEvent>
}
```

**Why `AsyncStream<IndexEvent>` (non-throwing):** per-file failures are emitted
as `.failed(URL, IndexFileError)` events; the stream itself never errors out.
Watcher init failures surface synchronously from `watch()` becoming `throws`
in v2 if needed; for v1, init failures crash with a `fatalError` since
FSEvents/DispatchSource initialization is essentially infallible given valid
paths.

**`onTermination` bridging to actor:** because `onTermination` is a `@Sendable`
sync closure, calling `await watcher.stop()` from inside it requires an
unstructured Task hop. The implementation pattern:

```swift
let (stream, cont) = AsyncStream.makeStream(of: IndexEvent.self,
                                            bufferingPolicy: bufferingPolicy)
let watcher = FileWatcher(paths: paths)
cont.onTermination = { [watcher] _ in
    Task { await watcher.stop() }   // unstructured; idempotent stop()
}
await watcher.start()
return stream
```

`FileWatcher.stop()` is **idempotent** by design (sets a flag, drains pending
callbacks, ignores subsequent FSEvents/DispatchSource notifications) so the
brief race between `onTermination` firing and a final platform callback is
harmless.

**FSEvents → actor delivery:** the FSEvents callback runs on a dispatch
queue. Inside the callback, events are pushed via `AsyncStream.makeStream`
continuation `yield(_:)` — which is sync and `Sendable`. The actor consumes
via `for await event in rawEvents`. Ordering is preserved by the stream's
buffer; we do not spawn one Task per event.

**Multi-subscriber semantics:** each call to `mem.watch()` constructs a
*new* `FileWatcher`. Two subscribers cause two FSEvents subscriptions —
acceptable since FSEvents is cheap, but documented. Hosts wanting
broadcast semantics share one stream via their own multiplexer.

**Backgrounding (iOS / visionOS):** the watcher cannot run while the app
is backgrounded. Hosts are responsible for `BGAppRefreshTask` scheduling
and re-running `index()` on next foreground.

## Compact (LLM summarization) — split into two halves

```swift
extension MemSearch {
    /// Generate the markdown summary in memory. No I/O.
    public func summarize<S: LLMSummarizer>(
        using summarizer: S,
        source: URL? = nil,
        promptTemplate: String? = nil
    ) async throws(MemSearchError) -> CompactedSummary

    /// Persist a previously-generated summary and re-index it.
    public func appendSummary(_ summary: CompactedSummary,
                              to outputDirectory: URL? = nil)
        async throws(MemSearchError) -> URL
}
```

Pipeline:

1. `store.scan(filter:)` → `AsyncThrowingStream<Chunk, VectorStoreError>`.
2. Collect content into the prompt template (`{chunks}` placeholder).
3. `summarizer.summarize(prompt:)` → markdown.
4. Return `CompactedSummary` to the caller.
5. (Caller decides:) `appendSummary(_:to:)` writes atomically to
   `(outputDirectory ?? paths[0]) / memory / proposedFilename`. First write
   to a fresh file gets a `# YYYY-MM-DD` header. Re-indexes that file.

Hosts wanting a preview UI: call `summarize`, show `summary.markdown`, then
call `appendSummary` only on user confirmation. CLI calls both back-to-back.

**Atomic writes:** `appendSummary` writes via a temp file + rename so
interrupted writes don't poison the next index.

**Security-scoped URLs (iOS):** if `outputDirectory` is a
security-scoped URL from `UIDocumentPicker`, the *host* is responsible for
calling `startAccessingSecurityScopedResource` before `appendSummary` and
`stopAccessing` after. Documented; not the library's job to manage.

## CLI (separate package)

Module: `MemSearch-CLI`'s `memsearch` executable.

```
memsearch <subcommand> [options]

  index                Scan paths and index markdown files. Streams progress.
  search <query>       Hybrid search; --json for plugin output
  expand <chunk-id>    Print full chunk by ID
  compact              Run LLM summarization, append to memory log
  watch                Run file watcher, auto-index on changes
  info                 Show store stats (chunks, sources, db path)
```

Built on `swift-argument-parser` with `AsyncParsableCommand`.

### Concrete-type dispatch — per-case helpers, no `some` in closure params

`(MemSearch<some VectorStore, some EmbeddingProvider>) async -> R` is illegal
per SE-0341 (opaque types in consuming positions of function type
parameters). Replaced by a finite switch that each calls a fully-monomorphic
helper:

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
                                embedder: try CoreMLEmbedder(...))
            try await runSearch(on: mem, query: query, topK: topK, json: json)
        // ... 8 total branches (2 stores × 4 embedders)
        }
    }
}

private func runSearch<V: VectorStore, E: EmbeddingProvider>(
    on mem: MemSearch<V, E>, query: String, topK: Int, json: Bool
) async throws { /* fully specialized per call */ }
```

8 branches per subcommand; hand-written or code-generated. No existentials in
the hot path.

### JSON output (search)

Same shape as before:

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

Two paths — programmatic for embedded use, TOML for the CLI / macOS power
users.

### Programmatic (first-class on iOS / visionOS)

iOS hosts have no shell, no `~/.config`, no `cwd`, no `Process.environment`
relevant to API keys. They construct everything directly:

```swift
let store = try await SQLiteVectorStore(url: containerURL(), dimension: 1024)
let embedder = OpenAIEmbedder(apiKey: keychainValue, baseURL: ...)
let mem = MemSearch(paths: [notesURL], store: store, embedder: embedder)
```

API keys come from the Keychain on iOS, not from environment variables.

### TOML (CLI, macOS, advanced power-user setups)

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

- `${VAR}` resolves to the value of `VAR`. If unset, raises
  `MemSearchError.configurationInvalid("environment variable VAR not set")`.
- `${VAR:-default}` resolves to `VAR`'s value, or `default` if unset.
- Literal `$` is escaped as `$$`.

### Defaults

- macOS CLI: store `sqlite`, embedder `coreml`, LLM auto-pick.
- iOS / visionOS programmatic: no defaults — explicit construction required.

## Concurrency posture

| Component                                           | Type                       | Why                                                                     |
| --------------------------------------------------- | -------------------------- | ----------------------------------------------------------------------- |
| `MemSearch<V, E>`                                   | `Sendable` struct          | Zero stored mutable state; isolation via `V`/`E`.                       |
| `SQLiteVectorStore`                                 | `final class : Sendable`   | GRDB `DatabasePool` is `Sendable` and provides reader concurrency.      |
| `SwiftDataVectorStore`                              | `@ModelActor`              | `ModelContext` is non-`Sendable`; `nonisolated let dimension` at init.  |
| `CoreMLEmbedder` / `ONNXEmbedder`                   | `final class : Sendable`   | Sync model load in `init`; per-call serialization via `OSAllocatedUnfairLock` if needed. |
| `OpenAIEmbedder` / `OllamaEmbedder`                 | `final class : Sendable`   | URLSession.shared only.                                                 |
| `OpenAICompatibleSummarizer`                        | `final class : Sendable`   | URLSession.shared only.                                                 |
| `FoundationModelsSummarizer`                        | `actor` + in-flight `Task` | Framework single-in-flight requirement; chained via stored task.        |
| `FileWatcher`                                       | `actor`                    | Wraps FSEvents / DispatchSource callbacks; `stop()` is idempotent.      |

`@unchecked Sendable` is **forbidden** in this design. `nonisolated(unsafe)`
is forbidden. `@TaskLocal` is reserved for tracing in v2.

### Cancellation

- `Task.checkCancellation()` between files in `index()` / `indexStream()` and
  between embedding batches.
- HTTP embedders / summarizer: URLSession async honors task cancellation.
- Core ML / ONNX: per-batch cancellation — cannot interrupt single inference.
- `mem.watch()` stream: `onTermination` calls `FileWatcher.stop()` via an
  unstructured Task hop; `stop()` is idempotent.
- Cancellation surfaces as `Swift.CancellationError`, **not** through the
  typed `MemSearchError` channel — typed throws don't catch
  `CancellationError`.
- Partial state on cancellation: per-file upserts are atomic (one
  transaction per file). Cancelling mid-run leaves consistent partial state;
  `index(force: false)` resumes idempotently via the diff.

## Error handling

```swift
public enum MemSearchError: Error, Sendable {
    case embedding(EmbeddingError)
    case store(VectorStoreError)
    case llm(LLMError)
    case scan(URL, any Error & Sendable)        // preserves cause structurally
    case chunking(URL, any Error & Sendable)
    case configurationInvalid(String)
    case noSummarizerConfigured
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

**`any Error & Sendable`** in associated values preserves the underlying
cause structurally without committing to a specific concrete type. Pattern-
matching on the underlying error works (`if case .embedding(.networkFailure(let e as URLError))`).

**`LocalizedError` conformance** is provided for every public error type so
SwiftUI's `.alert(isPresented:)` shows readable messages out of the box. v1
ships English-only `errorDescription`; localization via String Catalog is a
v2 add.

**No silent empties.** If a query errors, the API throws.

The watcher is the only place that swallows errors — failures surface as
`IndexEvent.failed(_, _)` not stream termination.

## Testing

Swift Testing (`@Test`, `#expect`, `#require`) — not XCTest, except a possible
performance ring-fence.

| Test target                       | Covers                                                                   |
| --------------------------------- | ------------------------------------------------------------------------ |
| `MemSearchTests`                  | Core types, chunker, RRF math, ChunkID stability, config layering, MemSearch orchestration with mocks, error mapping, `Sendable` invariant |
| `MemSearchSQLiteTests`            | Store CRUD, hybrid search end-to-end (single-tx), schema migration       |
| `MemSearchSwiftDataTests`         | Store CRUD, Accelerate cosine correctness, ModelActor isolation          |
| `MemSearchEmbeddersCoreMLTests`   | Sync model load, batch correctness, dimension precondition               |
| `MemSearchEmbeddersONNXTests`     | Same as Core ML                                                          |
| `MemSearchEmbeddersHTTPTests`     | Mock URLSession; OpenAI / Ollama protocol parsing, base_url override     |
| `MemSearch-CLITests` *(separate package)* | Subcommand parsing, config resolution, JSON output stability          |

### `package`-visible mocks (live in `MemSearch`)

Every mock supports per-call failure injection. Worked example:

```swift
package final class MockEmbeddingProvider: EmbeddingProvider {
    package nonisolated let modelName: String = "mock"
    package nonisolated let dimension: Int

    private let lock = OSAllocatedUnfairLock<State>(initialState: .init())
    package struct State { var calls = 0; var injectedFailures: [Int: EmbeddingError] = [:] }

    package init(dimension: Int = 8, injectedFailures: [Int: EmbeddingError] = [:]) {
        self.dimension = dimension
        lock.withLock { $0.injectedFailures = injectedFailures }
    }

    package func embed(_ texts: [String]) async throws -> [Embedding] {
        let callIndex = lock.withLock { state -> Int in
            defer { state.calls += 1 }
            return state.calls
        }
        if let injected = lock.withLock({ $0.injectedFailures[callIndex] }) {
            throw injected
        }
        // Deterministic vectors derived from text hash.
        return try texts.map { text in
            try Embedding(values: hashToFloats(text, dim: dimension), expectedDimension: dimension)
        }
    }
}

package final class MockVectorStore: VectorStore {
    // similar shape: nonisolated let dimension, lock-protected state, per-call failure injection
}

package struct MockSummarizer: LLMSummarizer {
    package let response: String
    package init(response: String = "(mock summary)") { self.response = response }
    package func summarize(prompt: String) async throws -> String { response }
}
```

### Negative-path coverage requirement

There is one test per `MemSearchError` constructor proving the underlying
cause is preserved structurally through the engine boundary — including
`Duration?` retry-after, `dimensionMismatch(expected:got:)` scalars, and
URL identity in `scan`/`chunking` cases.

### Determinism

ChunkID computation, chunker output, RRF scoring are pure — golden values.
No timing-based assertions. Watcher tests use `confirmation` over a temp
directory, not `Task.sleep`.

All test targets compile under `swiftLanguageModes: [.v6]`.

## Apple platform notes

### iOS / visionOS sandbox

- File watcher is best-effort. `DispatchSource.makeFileSystemObjectSource`
  per registered fd; no recursive directory watching. Hosts re-run `index()`
  manually on background → foreground transitions.
- `BGAppRefreshTask` scheduling is the host's responsibility, not the
  library's.
- Security-scoped URLs (from `UIDocumentPicker`): host is responsible for
  `startAccessingSecurityScopedResource` brackets.

### `@ModelActor SwiftDataVectorStore` ownership

- The store **owns its own `ModelContainer`** at a memsearch-managed URL
  (`Application Support/MemSearch/swiftdata.store`). It does **not** share
  the host's app-level container.
- Schema is `@Model public` so a host advanced enough to want a shared
  container can construct one and pass it via an alternate init. Default
  init is URL-only.
- `nonisolated let dimension: Int` is set in the custom (non-macro) init
  alongside the `ModelContainer` parameter.

### Core ML model lifecycle

See "Embedding providers / Core ML model lifecycle" above. Summary: opt-in
download via `preDownload(model:)`, models live in `Application Support/
MemSearch/Models/` with `isExcludedFromBackupKey = true`.

## SwiftUI integration (host pattern)

Not part of the library; documented here so every host doesn't rediscover.

### Type alias for environment storage

```swift
// In your app:
typealias AppMem = MemSearch<SQLiteVectorStore, OpenAIEmbedder>

@Observable @MainActor
final class MemModel {
    let mem: AppMem
    var indexState: IndexState = .idle
    var lastResults: [SearchHit] = []

    enum IndexState { case idle, indexing(progress: Int), completed(IndexStats), failed(MemSearchError) }

    init(mem: AppMem) { self.mem = mem }

    func search(_ q: String) async {
        do { lastResults = try await mem.search(q) }
        catch { /* present error */ }
    }

    func startIndex() async {
        indexState = .indexing(progress: 0)
        do {
            for try await event in mem.indexStream() {
                if case .indexed = event {
                    if case .indexing(let p) = indexState { indexState = .indexing(progress: p + 1) }
                }
            }
            indexState = .completed(IndexStats(...))
        } catch {
            indexState = .failed(error)
        }
    }
}
```

### Watcher subscription at app scope

```swift
@main struct MyApp: App {
    @State private var memModel: MemModel = {
        let mem: AppMem = ...
        return MemModel(mem: mem)
    }()

    var body: some Scene {
        WindowGroup { RootView().environment(memModel) }
            .task {
                for await event in memModel.mem.watch() {
                    // apply to memModel
                }
            }
    }
}
```

### `.task(id:)` for debounced search

```swift
struct SearchView: View {
    @Environment(MemModel.self) var model
    @State private var query: String = ""

    var body: some View {
        TextField("Search", text: $query)
            .task(id: query) {
                guard !query.isEmpty else { return }
                await model.search(query)   // earlier in-flight searches are auto-cancelled
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
- Default Core ML embedding model identifier — BGE-M3 is the working
  choice; verify it exists as a Core ML package via swift-transformers
  before locking in.
- 8-branch dispatch in CLI — hand-written vs `@resultBuilder`/macro
  generation. Decide based on how painful the hand-written version reads.
