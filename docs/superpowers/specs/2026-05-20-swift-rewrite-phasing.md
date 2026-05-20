# MemSearch Swift 6 Rewrite — Phasing Strategy

**Status:** draft (post-brainstorm)
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
- **Risk-spike upfront:** Phase 0 runs three throwaway spikes (~½ day
  each) on the highest-external-dep risks before Phase 1 starts.
- **Spec drift discipline:** if a phase reveals a spec error, fix the spec
  first (commit), then the implementation. Spec and code never diverge
  silently.

## Phase map

| Phase | Topic                              | Effort     | Outcome                                                           |
| ----- | ---------------------------------- | ---------- | ----------------------------------------------------------------- |
| 0     | Spikes                             | ~1.5 days  | External-dep risks validated; spec patched if needed              |
| 1     | MVP — library + minimal CLI        | ~1.5–2 wk  | First dogfoodable: `memsearch index/search/info` against SQLite + OpenAI |
| 2     | Core ML embedder                   | ~1 wk      | Offline embedding option; first-run model download lifecycle      |
| 3     | SwiftData store                    | ~1 wk      | Second backend; brute-force cosine via Accelerate                  |
| 4     | Watcher                            | ~1 wk      | `memsearch watch` running on macOS via FSEvents                    |
| 5     | ONNX + Ollama embedders            | ~1 wk      | All four embedders interchangeable                                 |
| 6     | Compact + summarizers              | ~1.5 wk    | OpenAI-compatible + FoundationModels; `summarize/appendSummary`    |
| 7     | Hardening + docs                   | ~1 wk      | Integration tests, benchmarks, README, CI matrix                   |

Total: ~7–9 weeks single-developer FTE. Estimates are rough.

## Phase 0 — Spikes

Three throwaway experiments. Code lives in `/tmp/memsearch-spikes/`, NOT in
the repo. Only result notes go to `docs/superpowers/spikes/`.

### Spike 0a — GRDB 7.x + sqlite-vec extension load

**Risk:** macOS system SQLite ships with extension loading disabled by
default. If GRDB uses system SQLite, `SELECT load_extension('vec0')`
fails. The whole `MemSearchSQLite` design depends on this working.

**Approach:**

1. Minimal SwiftPM scratch package with `GRDB.swift 7.x` + `sqlite-vec`
   deps.
2. `Configuration.prepareDatabase { db in try db.execute(sql:
   "SELECT load_extension('vec0')") }`.
3. `CREATE VIRTUAL TABLE chunks USING vec0(embedding float[1024])`,
   INSERT one vector, run a KNN SELECT.

**Done when:** the KNN SELECT returns the inserted vector.

**Failure mode → spec patch:**
- (a) ship `SQLite3-static` SPM dep to bundle a permissive SQLite build,
  OR
- (b) use GRDB's `SQLiteCustomBuild` mode, OR
- (c) drop sqlite-vec, fall back to brute-force cosine over BLOB
  embeddings (still hybrid via FTS5 + Swift cosine).

### Spike 0b — swift-transformers Core ML embedding model

**Risk:** swift-transformers may not ship a usable Core ML BGE-M3
package; we may need a different default.

**Approach:**

1. Attempt `AutoTokenizer.from(modelFolder: …)` against BGE-M3.
2. Attempt `MLModel(contentsOf: …)` against the corresponding
   `.mlpackage`.
3. Embed `"hello world"`, verify dimension matches docs.
4. If BGE-M3 unavailable, repeat with `all-MiniLM-L6-v2`.

**Done when:** any reasonable embedding model loads end-to-end.

**Failure mode → spec patch:** pin the working model identifier in the
Risks section; update Phase 2's deliverables.

### Spike 0c — FoundationModels single-flight stress test

**Risk:** the spec's chained-Task pattern still races; or
`LanguageModelSession` has constraints we missed. Requires macOS 26
hardware.

**Approach:**

1. Build a minimal `actor StressActor` with the spec's exact pattern
   (`inFlight: Task<String, Error>?`, spawn-then-assign,
   `[weak self]` capture).
2. Spawn 10 concurrent `Task`s each calling `actor.summarize(prompt:)`.
3. Run 100 iterations.

**Done when:** 1000 calls, zero `LanguageModelSession.GenerationError.*`
related to concurrency.

**Failure mode → spec patch:** revise the single-flight pattern;
consult Apple sample code.

**Skip if no macOS 26 hardware available** — defer to Phase 6 prep.

### Phase 0 deliverables

- `docs/superpowers/spikes/2026-05-20-spike-0a-sqlite-vec.md`
- `docs/superpowers/spikes/2026-05-20-spike-0b-coreml-bge.md`
- `docs/superpowers/spikes/2026-05-20-spike-0c-foundationmodels.md`
- Any spec patches required by spike findings

**Exit criterion:** all three spikes have a result note (or explicit
skip), and the design spec reflects any architectural pivots.

## Phase 1 — MVP (Library + minimal CLI)

The first vertical slice. Proves the architecture end-to-end.

### Deliverables

**`MemSearch` library:**

- All public types (Models/, Errors/) with `LocalizedError` conformances.
- All three protocols (`VectorStore`, `EmbeddingProvider`,
  `LLMSummarizer` — last unused but declared).
- `MemSearch<V, E>` engine with `init`, `index`, `indexStream`,
  `indexFile`, `search` implemented; `summarize` / `appendSummary` /
  `watch` declared but throw `.unimplemented`.
- `Chunker` (heading-based, deterministic, matches Python).
- `RRF.fuse` helper.
- `Scanner` (FileManager.enumerator).
- `Configuration` value types (TOML loading lives in CLI package).
- Mocks: `MockEmbeddingProvider`, `MockVectorStore`, `MockSummarizer`
  (package-visible, content-keyed failure injection).

**`MemSearchSQLite` library:**

- `SQLiteVectorStore` (final class : Sendable wrapping `DatabasePool`).
- Schema + GRDB migrations.
- sqlite-vec extension loading via `Configuration.prepareDatabase`.
- FTS5 + bm25.
- `hybridSearch` running both queries inside one `pool.read { db in ... }`.

**`MemSearchEmbeddersHTTP` library:**

- `OpenAIEmbedder` only (Ollama deferred to Phase 5).
- `URLSession.shared` async API.
- `URLError(.cancelled)` → `CancellationError` translation.

**`MemSearch-CLI` package:**

- `swift-argument-parser` entry point.
- Subcommands: `index`, `search`, `info`.
- TOML config loader (basic; full env-var resolution can wait).
- Per-case dispatch — only 1 store × 1 embedder = 1 case in MVP.
- JSON output for `search`.

### Tests

- **TDD (red-green-refactor):** chunker (golden-file fixtures),
  `RRF.fuse` math, `ChunkID` stability, error-lifting helper, SQLite
  CRUD, `hybridSearch` single-tx invariant.
- **Test-after:** Scanner, CLI flag plumbing, TOML loader.

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

### What we explicitly skip

Core ML, SwiftData, watcher, other embedders, compact/summarizers,
String Catalog localization, performance benchmarks, integration tests
across phases.

### Phase 1 effort

~1.5–2 weeks single-developer; ~30 source files.

## Phase 2 — Core ML embedder (~1 wk)

- **Add:** `MemSearchEmbeddersCoreML` module with `CoreMLEmbedder`
  actor; `async throws` init (`Tokenizer.from(modelFolder:)` is async).
- **Wire:** `preDownload(model:)` API; model dir at `Application
  Support/MemSearch/Models/` with `isExcludedFromBackupKey = true`.
- **CLI dispatch:** 2 cases (1 store × 2 embedders).
- **Tests (TDD):** dimension precondition, async model load, batch
  correctness via deterministic golden vectors.
- **Success:** `memsearch index --embedder coreml` works offline; first
  run downloads, second run uses cache.
- **Spec dependency:** Phase 0b spike result — default model identifier
  is whatever 0b validated.

## Phase 3 — SwiftData store (~1 wk)

- **Add:** `MemSearchSwiftData` with `actor SwiftDataVectorStore:
  ModelActor` (manual, no macro), `StoredChunkRecord` `@Model`,
  brute-force cosine via `vDSP_dotpr`.
- **CLI dispatch:** 4 cases (2 stores × 2 embedders).
- **Tests (TDD):** CRUD, cosine correctness against numpy reference
  values, manual ModelActor isolation under concurrent search.
- **Success:** SwiftData backend's top hits semantically match SQLite's
  on the same fixture (≥70% overlap). Performance acceptable at 50k
  chunks.
- **Note:** dense-only — no BM25; `score = denseScore`.

## Phase 4 — Watcher (~1 wk)

- **Add:** `FileWatcher` actor with FSEvents (macOS,
  `kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer`)
  + DispatchSource (iOS) gated by `#if os()`. `MemSearch.watch()`
  throwing init returning `AsyncStream<IndexEvent>`. Debouncer.
- **CLI:** `memsearch watch` subcommand prints `IndexEvent` JSON per
  line.
- **Tests (TDD):** golden-path created/modified/deleted using
  `confirmation` over a tempdir; Instruments-validated no-leak teardown.
- **Success:** `memsearch watch` runs; mutations debounce → re-index;
  Ctrl+C cleanly stops; no leaked fds; no retain cycle (`[weak watcher]`
  in `onTermination`).

## Phase 5 — ONNX + Ollama embedders (~1 wk)

- **Add:** `MemSearchEmbeddersONNX` with `ONNXEmbedder` actor;
  `OllamaEmbedder` (final class) into `MemSearchEmbeddersHTTP`
  (auto-detects dimension via trial embed in async init).
- **CLI dispatch:** 8 cases (2 × 4). Hand-written acceptable; macro
  generation deferred to Phase 7 if it gets unwieldy.
- **Tests (TDD):** ONNX model load + batch; Ollama trial-embed
  dimension detection (mocked URLSession).
- **Success:** all 4 embedders produce comparable top-K rankings on the
  same fixture (≥70% overlap pairwise).

## Phase 6 — Compact + summarizers (~1.5 wk)

- **Add:** `OpenAICompatibleSummarizer` (final class).
  `FoundationModelsSummarizer` actor with the spec's corrected
  single-flight pattern (Spike 0c validated). `LanguageModelSession.GenerationError`
  → `LLMError` mapping per spec.
- **Engine:** `summarize(...) -> CompactedSummary` (with `dateStamp:
  Date`) + `appendSummary(_:to:)` (atomic temp-file + rename).
- **CLI:** `memsearch compact` with `--llm`, `--source`, `--preview`
  flags. `--preview` prints summary without writing.
- **CLI dispatch:** 16 cases (2 × 4 × 2). Strongly consider macro
  generation now.
- **Tests (TDD):** end-to-end summarize + appendSummary + re-index;
  `dateStamp` survives next-day-append; concurrent stress test on
  `FoundationModelsSummarizer` (CI-skipped on < macOS 26).
- **Success:** `memsearch compact --source path.md --llm openai` writes
  daily memory log; same with `--llm foundation-models` works on macOS
  26.

## Phase 7 — Hardening + docs (~1 wk)

- **Add:** integration tests (full index → search → compact → re-index);
  benchmarks (chunks/sec indexed, query p50/p99 latency); README with
  Quick Start + SwiftUI integration; CI matrix (macOS + iOS
  compile-only).
- **Polish:** `LocalizedError` strings reviewed; full env-var resolution
  in TOML loader; macro-based CLI dispatch if hand-written hit pain
  points; LICENSE / CONTRIBUTING if missing.
- **Success:** README sufficient for a new contributor to integrate the
  library; benchmarks committed; CI green; all phases' tests pass
  together.

## Cross-cutting concerns

### Per-phase rituals

Every phase ends with:

1. `swift test` green.
2. `swift build` green for every product.
3. Commit, push.
4. `docs/superpowers/phases/phase-N-notes.md` capturing surprises,
   spec deltas, deferred items.

### What we explicitly do NOT do during Phases 1–6

- Add features beyond the spec.
- Style refactors of code we didn't touch.
- Build SwiftUI host apps.
- Write OpenClaw / OpenCode / Codex plugin replacements (post-v1).
- Premature performance optimization (real numbers come from Phase 7
  benchmarks).

### Deferred to v2

- Cross-encoder reranker.
- BM25 inside SwiftData backend.
- Token streaming through `LLMSummarizer`.
- `MLXLocalSummarizer`.
- On-disk format migration from Python `memsearch`.
- Plugin clients (Claude Code, OpenCode, Codex, OpenClaw).
- watchOS / tvOS support.
- TOML String Catalog localization.

### Spec patches during phases

If a phase reveals a spec error:

1. Fix the spec first; commit with `docs: spec patch — <reason>`.
2. Then update the implementation.

Never let spec and code diverge silently. Spec is the single source of
truth for design decisions; code is the single source of truth for
behavior; they should match.

## After Phase 7

- v1 release (tag, GitHub release).
- Decide on v2 priorities based on real usage.
- Plugin client work (post-v1) is its own brainstorm → spec → plan
  cycle, separate from this rewrite.
