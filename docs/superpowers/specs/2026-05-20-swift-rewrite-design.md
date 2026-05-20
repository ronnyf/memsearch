# Memsearch Swift 6 Rewrite — Design

**Status:** draft (post-brainstorm)
**Date:** 2026-05-20
**Issue:** #1

## Goals

Port the Python `memsearch` library to Swift 6 as an Apple-platform-idiomatic
package. Not a literal port — fresh API in Swift idioms, leveraging native
Apple primitives where they're a better fit than the Python equivalents.

**In scope (v1):**

- Library: chunker, indexing, hybrid search, embeddings, file watcher,
  LLM-powered compact, configuration.
- Two open-source vector store backends: SQLite (GRDB + FTS5 + sqlite-vec) and
  SwiftData.
- Four embedding providers: Core ML (default), OpenAI, Ollama, ONNX Runtime.
- Two LLM summarizers: OpenAI-compatible HTTP and on-device FoundationModels
  (gated by availability).
- CLI executable using swift-argument-parser.

**Out of scope (v1, may revisit):**

- Cross-encoder reranker.
- BM25 inside the SwiftData backend.
- Token streaming through the summarizer protocol.
- Migration tools from the Python on-disk format.
- Plugin clients (Claude Code, OpenCode, etc.). They'll consume the new CLI
  later as a follow-up project.

## Non-goals

- Linux compatibility. macOS + iOS family only.
- Python interop. Greenfield Swift; not a callable layer over the existing
  package.
- Wire-compatibility with Python `memsearch`'s on-disk format.

## Platforms

- macOS 14+
- iOS 17+
- visionOS 1+

The `FoundationModelsSummarizer` requires macOS 26 / iOS 26 / visionOS 26 and
an Apple Intelligence-capable device — gated behind `@available`.

## Architecture

### Module layout

```
Package: Memsearch
swiftLanguageModes: [.v6]
upcomingFeatures: [.ApproachableConcurrency]

Modules
├── Memsearch                library  (protocols, chunker, engine, embedders, watcher, compact, config)
├── MemsearchSQLite          library  (SQLite store via GRDB + FTS5 + sqlite-vec)
├── MemsearchSwiftData       library  (SwiftData store with Accelerate cosine)
└── memsearch                executable  (swift-argument-parser CLI; depends on Memsearch + both stores)
```

The protocol-first split is the whole point: adding a future backend is a new
sibling module that conforms to `VectorStore`, no engine-side change.

### External dependencies

| Package                | Purpose                                          |
| ---------------------- | ------------------------------------------------ |
| swift-argument-parser  | CLI parsing, subcommands                         |
| swift-transformers     | Core ML embedder + tokenization                  |
| GRDB.swift (7.x)       | SQLite wrapper, FTS5, migrations, DatabasePool   |
| sqlite-vec             | SQLite extension for ANN vector search           |
| swift-toml / swift-tomlkit | Config parsing                               |

### Module access

`public` is reserved for the curated external API surface (the protocols,
`MemSearch<V, E>`, the result/error types, the concrete embedder/summarizer
types). Cross-module internals use `package` access so sibling targets in this
package can reach into `Memsearch`'s implementation without leaking through to
consumers.

## Core types

All public types are `Sendable` value types. Errors use typed throws at every
protocol boundary.

```swift
public struct ChunkID: Hashable, Sendable, RawRepresentable {
    public let rawValue: String   // composite: hash(source:lines:contentHash:model)
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

public struct Embedding: Sendable, Hashable {
    public let values: [Float]
    public var dimension: Int { values.count }
}

public struct StoredChunk: Sendable {
    public let chunk: Chunk
    public let embedding: Embedding
}

public struct SearchHit: Sendable, Hashable {
    public let chunk: Chunk
    public let score: Float           // RRF-normalized, [0, 1]
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

public enum WatchEvent: Sendable {           // raw FS events
    case created(URL), modified(URL), deleted(URL)
}

public enum IndexEvent: Sendable {           // engine-level outcomes
    case indexed(URL, chunkCount: Int)
    case removed(URL)
    case failed(URL, MemSearchError)
}
```

## Protocols

```swift
public protocol EmbeddingProvider: Sendable {
    var modelName: String { get }
    var dimension: Int { get }
    func embed(_ texts: [String]) async throws(EmbeddingError) -> [Embedding]
}

public protocol VectorStore: Sendable {
    var dimension: Int { get }

    func upsert(_ records: [StoredChunk]) async throws(VectorStoreError) -> Int
    func hybridSearch(_ query: HybridQuery) async throws(VectorStoreError) -> [SearchHit]
    func scan(filter: SourceFilter?) async throws(VectorStoreError)
        -> AsyncThrowingStream<Chunk, any Error>
    func indexedSources() async throws(VectorStoreError) -> Set<URL>
    func chunkIDs(forSource: URL) async throws(VectorStoreError) -> Set<ChunkID>
    func delete(ids: [ChunkID]) async throws(VectorStoreError) -> Int
    func delete(source: URL) async throws(VectorStoreError) -> Int
    func close() async
}

public protocol LLMSummarizer: Sendable {
    func summarize(prompt: String) async throws(LLMError) -> String
}
```

**Why hybrid search lives in `VectorStore`, not the engine:** SQLite + FTS5 +
sqlite-vec can co-locate the two queries inside a single read transaction; a
future engine-side backend can fuse natively. Forcing the engine to do two
round-trips would defeat both backends.

**Why `AsyncThrowingStream<Chunk, _>` for `scan`:** the compact path needs to
walk every chunk for a source — streaming avoids loading the whole collection
into memory. Iteration uses `withTaskCancellationHandler` to stay legal under
strict concurrency.

## Engine

`MemSearch` is generic over the store and embedder — no existential boxing in
the hot path.

```swift
public struct MemSearch<V: VectorStore, E: EmbeddingProvider>: Sendable {
    public let paths: [URL]
    public let store: V
    public let embedder: E
    public let chunkingPolicy: ChunkingPolicy

    public init(paths: [URL],
                store: V,
                embedder: E,
                chunkingPolicy: ChunkingPolicy = .default)

    public func index(force: Bool = false) async throws(MemSearchError) -> IndexStats
    public func indexFile(_ url: URL) async throws(MemSearchError) -> Int
    public func search(_ query: String,
                       topK: Int = 10,
                       filter: SourceFilter? = nil) async throws(MemSearchError) -> [SearchHit]
    public func compact<S: LLMSummarizer>(
        using summarizer: S,
        source: URL? = nil,
        promptTemplate: String? = nil,
        outputDirectory: URL? = nil
    ) async throws(MemSearchError) -> URL
    public func watch(debounce: Duration = .milliseconds(250))
        -> AsyncThrowingStream<IndexEvent, any Error>
}
```

The `Sendable` conformance comes for free from `V: VectorStore` ⇒ `V: Sendable`
and `E: EmbeddingProvider` ⇒ `E: Sendable`. No `@unchecked` needed anywhere.

## Indexing pipeline

```
scan ─► chunk ─► diff against store ─► embed (batched) ─► upsert
                              │
                              └─► delete stale chunks (per file + per orphaned source)
```

Sequential across files in v1 — predictable, kind to API rate limits, easy to
reason about. Per-file the engine:

1. Reads the file as UTF-8.
2. Calls `Chunker.chunk(...)`.
3. Computes ChunkIDs and diffs against `store.chunkIDs(forSource:)`.
4. Deletes stale IDs for that source.
5. Embeds only new chunks via `embedder.embed(_:)` — the provider batches
   internally so the engine doesn't need to know batch sizes.
6. Upserts the resulting `StoredChunk`s.

After all files, the engine compares `store.indexedSources()` against the
active set and deletes orphaned sources (handles deletion of files since last
index).

`Chunker` is an `enum` namespace of pure functions — no protocol, no state.
Implementation matches the Python heading-based splitter (`max_chunk_size`,
`overlap_lines`).

A future v2 can parallelize across files via `withThrowingTaskGroup` behind a
`concurrency: Int` knob without changing the public surface.

## Search

```swift
public func search(_ query: String, topK: Int, filter: SourceFilter?) async throws -> [SearchHit] {
    let qVec = try await embedder.embed([query])[0]
    let hq = HybridQuery(queryText: query, queryEmbedding: qVec,
                         topK: topK, filter: filter, rrfK: 60)
    return try await store.hybridSearch(hq)
}
```

### RRF (Reciprocal Rank Fusion)

`package`-visible helper used by every store implementation:

```swift
package enum RRF {
    /// Theoretical max for normalization = numRetrievers / (k + 1)
    package static func fuse(_ rankings: [[ChunkID]],
                             k: Int = 60,
                             topK: Int) -> [(ChunkID, Float)]
}
```

### Backend strategies

| Backend              | Vector path                                       | BM25 path        | Fusion                                                   |
| -------------------- | ------------------------------------------------- | ---------------- | -------------------------------------------------------- |
| `MemsearchSQLite`    | `sqlite-vec` ANN                                  | `FTS5 bm25()`    | Swift `RRF.fuse` over the two ID lists, single read tx   |
| `MemsearchSwiftData` | Brute-force cosine via `vDSP_dotpr` + `#Predicate` | *(none in v1)*  | Single-ranking RRF (still normalizes to `[0, 1]`)        |

## Embedding providers (v1)

| Provider                    | Type                | Notes                                                                                  |
| --------------------------- | ------------------- | -------------------------------------------------------------------------------------- |
| `CoreMLEmbedder`            | `actor`             | Default. swift-transformers + Core ML. ANE on iOS, GPU/CPU on macOS. Zero-config.       |
| `OpenAIEmbedder`            | `Sendable struct`   | `URLSession` async. Honors `base_url` for OpenAI-compatible servers (LM Studio, etc.). |
| `OllamaEmbedder`            | `Sendable struct`   | HTTP to `localhost:11434`. Auto-detects dimension via trial embed.                     |
| `ONNXEmbedder`              | `actor`             | swift-onnxruntime. Same model files as the Python project's `onnx` provider.            |

All conform to `EmbeddingProvider` and are valid generic params for `MemSearch`.

## LLM summarizers (v1)

| Summarizer                       | Min platforms                      | Hardware                          | Type     |
| -------------------------------- | ---------------------------------- | --------------------------------- | -------- |
| `OpenAICompatibleSummarizer`     | macOS 14, iOS 17, visionOS 1       | Any                               | struct   |
| `FoundationModelsSummarizer`     | macOS 26, iOS 26, visionOS 26      | Apple Intelligence-capable device | actor    |

`MLXLocalSummarizer` is planned post-v1 (Apple Silicon, no version gate beyond
`mlx-swift`'s own minimums). The `LLMSummarizer` protocol is forward-compatible
— adding it is purely additive.

### `LLMError`

```swift
public enum LLMError: Error, Sendable {
    case unavailable
    case authenticationFailed
    case rateLimited
    case contextWindowExceeded
    case unsupportedLocale
    case networkFailure(description: String)
    case invalidResponse
    case modelFailure(description: String)
}
```

## File watcher

Two layers:

- **Internal `FileWatcher` actor** wraps platform primitives.
  - macOS: `FSEventStreamCreate` recursive.
  - iOS: `DispatchSource.makeFileSystemObjectSource` per registered path.
    Recursive watching is degraded — directory additions aren't auto-discovered;
    callers re-run `index()` manually. Documented limitation.
- **Public `MemSearch.watch()`** subscribes to `FileWatcher`, debounces, drives
  indexing, yields `AsyncThrowingStream<IndexEvent, any Error>`.

`onTermination` on the public stream calls `FileWatcher.stop()`. Failures
during indexing become `IndexEvent.failed(_, _)` rather than tearing down the
stream — a single bad file can't kill the watcher.

## Compact (LLM summarization)

```swift
extension MemSearch {
    public func compact<S: LLMSummarizer>(
        using summarizer: S,
        source: URL? = nil,
        promptTemplate: String? = nil,
        outputDirectory: URL? = nil
    ) async throws(MemSearchError) -> URL
}
```

Pipeline:

1. `store.scan(filter:)` → `AsyncThrowingStream<Chunk, _>`.
2. Collect content into the prompt template (`{chunks}` placeholder).
3. `summarizer.summarize(prompt:)` → markdown summary.
4. Append to `outputDirectory ?? paths[0]` / `memory/YYYY-MM-DD.md`. First write
   to a fresh file gets a `# YYYY-MM-DD` header.
5. Re-index that file immediately (markdown stays the single source of truth).
6. Return the file URL.

Summarizer is a method-level generic, not stored on `MemSearch` — compact is
infrequent and not every host wants to pay for the dependency.

## CLI

```
memsearch <subcommand> [options]

  index                Scan paths and index markdown files
  search <query>       Hybrid search; --json for plugin output
  expand <chunk-id>    Print full chunk by ID
  compact              Run LLM summarization, append to memory log
  watch                Run file watcher, auto-index on changes
  info                 Show store stats (chunks, sources, db path)
```

Built on `swift-argument-parser` with `AsyncParsableCommand`. Concrete-type
dispatch in a single helper:

```swift
package func withBackends<R: Sendable>(
    _ cfg: ResolvedConfig,
    body: (MemSearch<some VectorStore, some EmbeddingProvider>) async throws -> R
) async throws -> R {
    switch (cfg.store.backend, cfg.embedder.provider) {
    case (.sqlite, .openai):    /* construct concretes, call body */
    case (.sqlite, .coreML):    ...
    case (.sqlite, .ollama):    ...
    case (.sqlite, .onnx):      ...
    case (.swiftData, .openai): ...
    case (.swiftData, .coreML): ...
    case (.swiftData, .ollama): ...
    case (.swiftData, .onnx):   ...
    }
}
```

Bounded 2 × 4 = 8 branches. No `any` in the hot path; compiler specializes
each branch.

### JSON output (search)

```json
{
  "hits": [
    {
      "chunk_id": "abc123…",
      "source": "/abs/path/notes/2026-05-19.md",
      "heading": "Memsearch design",
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

Layered: built-in defaults → `~/.config/memsearch/config.toml` →
`./.memsearch.toml` (cwd) → CLI flags. Last writer wins, deep-merged.
`${VAR}` and `${VAR:-default}` are resolved at load time (matches the Python
project's `resolve_env_ref` semantics).

```toml
paths = ["~/Documents/notes"]

[store]
backend = "sqlite"                              # sqlite | swiftdata
path    = "~/Library/Application Support/Memsearch/memory.db"

[embedder]
provider   = "coreml"                           # coreml | openai | ollama | onnx
model      = "BGE-M3"
batch_size = 32

[llm]
provider = "foundation-models"                  # foundation-models | openai-compat
model    = "gpt-4o-mini"
base_url = "https://api.openai.com/v1"
api_key  = "${OPENAI_API_KEY}"

[chunking]
max_chunk_size = 1500
overlap_lines  = 2
```

### Defaults

- Store: `sqlite` at `~/Library/Application Support/Memsearch/memory.db` on
  macOS; `Application Support` container on iOS.
- Embedder: `coreml` (zero-config). First run downloads the Core ML model
  package via swift-transformers.
- LLM: `foundation-models` if `SystemLanguageModel.default.isAvailable`, else
  `openai-compat` reading `OPENAI_API_KEY`.

## Concurrency posture

| Component                                            | Type              | Why                                                                |
| ---------------------------------------------------- | ----------------- | ------------------------------------------------------------------ |
| `MemSearch<V, E>`                                    | `Sendable` struct | No internal mutable state; isolation comes from `V`/`E`.            |
| `SQLiteVectorStore`                                  | `actor`           | GRDB `DatabasePool` inside; serial scheduling.                      |
| `SwiftDataVectorStore`                               | `@ModelActor`     | `ModelContext` is non-`Sendable`.                                   |
| `OpenAIEmbedder` / `OllamaEmbedder`                  | `Sendable` struct | `URLSession` is `Sendable`; nothing to guard.                       |
| `CoreMLEmbedder` / `ONNXEmbedder`                    | `actor`           | `MLModel` / `ORTSession` aren't `Sendable`.                         |
| `OpenAICompatibleSummarizer`                         | `Sendable` struct | Stateless HTTP.                                                     |
| `FoundationModelsSummarizer`                         | `actor`           | Single in-flight request requirement.                               |
| `FileWatcher`                                        | `actor`           | Wraps FSEvents/DispatchSource callbacks.                            |

`@unchecked Sendable` does not appear anywhere in the design. `nonisolated(unsafe)`
does not appear. `@TaskLocal` is not used in v1.

### Cancellation

- `Task.checkCancellation()` is called between files in `index()` and between
  embedding batches.
- `mem.watch()`'s stream uses `onTermination` to call `FileWatcher.stop()`.
- Iterating non-`Sendable` AsyncSequences inside a `Task` uses
  `withTaskCancellationHandler` (its `operation` closure isn't `@Sendable`).
- HTTP requests use `URLSession`'s async API, which honors task cancellation.

## Error handling

Union at the engine boundary, narrow types at each protocol boundary.

```swift
public enum MemSearchError: Error, Sendable {
    case embedding(EmbeddingError)
    case store(VectorStoreError)
    case llm(LLMError)
    case scan(URL, description: String)
    case chunking(URL, description: String)
    case configurationInvalid(String)
    case noSummarizerConfigured
}

public enum EmbeddingError: Error, Sendable {
    case authenticationFailed
    case rateLimited(retryAfter: Duration?)
    case dimensionMismatch(expected: Int, got: Int)
    case modelNotFound(String)
    case networkFailure(description: String)
    case decodingFailed(description: String)
}

public enum VectorStoreError: Error, Sendable {
    case connectionFailed(description: String)
    case schemaIncompatible(reason: String)
    case dimensionMismatch(expected: Int, got: Int)
    case backendError(description: String)
}
```

**No silent empties.** If a query errors, the API throws — it does not return
`[]`. The watcher is the only place that swallows errors, and only because
losing the daemon over a single bad file is worse than skipping it; failures
surface as `IndexEvent.failed(_, _)`.

## Testing

Swift Testing (`@Test`, `#expect`, `#require`) — not XCTest, except a possible
performance ring-fence.

| Test target               | Covers                                                                   |
| ------------------------- | ------------------------------------------------------------------------ |
| `MemsearchTests`          | Core types, chunker, RRF math, ChunkID stability, config layering & env expansion, MemSearch orchestration with mocks |
| `MemsearchSQLiteTests`    | Store CRUD, hybrid search end-to-end, dimension mismatch, schema migration |
| `MemsearchSwiftDataTests` | Store CRUD, Accelerate cosine correctness, ModelActor isolation          |
| `memsearchCLITests`       | Subcommand parsing, config resolution, JSON output stability             |

`package`-visible mocks live in `Memsearch`:

```swift
package struct MockEmbeddingProvider: EmbeddingProvider { ... }
package actor MockVectorStore: VectorStore { ... }
package struct MockSummarizer: LLMSummarizer { ... }
```

Determinism: ChunkID computation, chunker output, and RRF scoring are pure —
assertable with golden values. No timing-based assertions. Watcher tests use
`confirmation` over a temp directory, not `Task.sleep`.

All test targets compile under `swiftLanguageModes: [.v6]` like the libraries.
Any non-`Sendable` capture is a compile failure.

## Open questions

None blocking. Items deferred to implementation:

- swift-toml vs swift-tomlkit — pick the one with cleaner Swift 6 Sendable
  conformances at impl time.
- sqlite-vec distribution — SPM binary target if available, otherwise
  prebuilt `.a` linked via `linkerSettings`.
- Default Core ML embedding model — BGE-M3 is the working choice; verify it
  exists as a Core ML package via swift-transformers before locking in.
