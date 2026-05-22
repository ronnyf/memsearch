# MemSearch Swift 6 Rewrite — Phase 1 (MVP) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the MVP — a `MemSearch` Swift library + a minimal `memsearch` CLI that can `index` / `search` / `info` against a notes folder using SQLite (sqlite-vec + FTS5 + RRF) and OpenAI embeddings. Phase 1 ends green on `swift test`, the per-phase iOS-Simulator compile gate, and the seven success criteria from the phasing doc.

**Architecture:** Two SwiftPM packages.

- **Library package** (this repo's `Package.swift`) exposes four library products:
  - `MemSearch` — engine, value types, errors, protocols, chunker, RRF, mocks.
  - `MemSearchSQLite` — `SQLiteVectorStore` (`final class : Sendable` over GRDB `DatabasePool`).
  - `MemSearchEmbeddersHTTP` — `OpenAIEmbedder` only (Ollama defers to Phase 5).
  - `SQLiteVec` — vendored C wrapper around `asg017/sqlite-vec` v0.1.9 (source-linked, static).
- **CLI package** (sibling SPM package under `cli/`) depends on the library package and ships the `memsearch` executable.

`MemSearch<V, E>` is a `Sendable` generic struct with zero stored mutable state. `summarize` / `appendSummary` / `watch` declare the v1 surface but throw `MemSearchError.unimplemented("<feature>: implemented in Phase N")`.

**Tech Stack:** Swift 6.0+ (`swiftLanguageModes: [.v6]`, `enableUpcomingFeature("ApproachableConcurrency")`), GRDB.swift 7.x, sqlite-vec v0.1.9, Foundation/URLSession (system), swift-argument-parser, Swift Testing (`@Test` / `#expect` / `#require`).

**Reference docs (read before starting):**

- `docs/superpowers/specs/2026-05-20-swift-rewrite-design.md` — authoritative design.
- `docs/superpowers/specs/2026-05-20-swift-rewrite-phasing.md` — Phase 1 deliverables, success criteria, per-phase rituals, "Deferred to v2".
- `docs/superpowers/phases/phase-0-notes.md` — Phase 1 entry checklist + Phase 0 spec deltas.
- `docs/superpowers/spikes/2026-05-20-spike-0a-sqlite-vec.md` — sqlite-vec integration shape (`sqlite3_vec_init` direct call; static-link via custom SwiftPM wrapper).
- `docs/superpowers/spikes/2026-05-20-spike-0b-coreml-bge.md` — `nonisolated let dimension` actor init shape (informs `EmbeddingProvider`).
- `src/memsearch/chunker.py` — Python chunker; the Swift `Chunker` mirrors heading-split + `compute_chunk_id` byte-for-byte for the cross-check.

**Phase 1 entry checklist (carried from `phase-0-notes.md`):**

- Spec coherent against all three Phase 0 spikes.
- Python ground-truth fixture (`tests/fixtures/python-baseline/python-top5.json` + `.sha256` + `manifest.json`) exists.
- Decision recorded for sqlite-vec wrapper hosting (vendor vs fork).
- `Package.swift` declares `[.macOS(.v14), .iOS(.v17), .visionOS(.v1)]` and the canonical iOS-Simulator compile-gate command is pinned in `phase-1-notes.md`.

Task 1 closes every entry-checklist item before any new code is written.

**Out of scope this phase (per phasing doc):** Core ML, SwiftData, watcher, ONNX/Ollama embedders, compact/summarizers, iOS-runtime validation, performance benchmarks, integration tests across phases, full env-var resolution beyond `${VAR}` and `${VAR:-default}`, YAML/TOML config file support (JSON-only in v1; loader is format-dispatched so adding YAML/TOML later requires only a new case).

---

## File Structure

### Library package (this repo)

```
Package.swift                                                  # rewritten — multi-product
Sources/
├── MemSearch/
│   ├── Models/
│   │   ├── ChunkID.swift
│   │   ├── Chunk.swift
│   │   ├── Embedding.swift
│   │   ├── StoredChunk.swift
│   │   ├── SearchHit.swift
│   │   ├── HybridQuery.swift
│   │   ├── SourceFilter.swift
│   │   ├── IndexStats.swift
│   │   ├── ChunkingPolicy.swift
│   │   ├── IndexEvent.swift
│   │   ├── IndexFileError.swift
│   │   ├── CompactedSummary.swift
│   │   └── EngineSummary.swift
│   ├── Errors/
│   │   ├── MemSearchError.swift
│   │   ├── EmbeddingError.swift
│   │   ├── VectorStoreError.swift
│   │   ├── LLMError.swift
│   │   └── LocalizedDescriptions.swift
│   ├── Protocols/
│   │   ├── VectorStore.swift
│   │   ├── EmbeddingProvider.swift
│   │   └── LLMSummarizer.swift
│   ├── Engine/
│   │   ├── MemSearch.swift              # struct + init + search
│   │   ├── MemSearch+Indexing.swift     # index, indexStream, indexFile
│   │   ├── MemSearch+Stubs.swift        # summarize/appendSummary/watch — throw .unimplemented
│   │   └── ErrorLifting.swift           # private package helper
│   ├── Chunker/
│   │   └── Chunker.swift
│   ├── RRF/
│   │   └── RRF.swift                    # package-visible
│   ├── Scanner/
│   │   └── Scanner.swift
│   └── Mocks/
│       ├── MockEmbeddingProvider.swift
│       ├── MockVectorStore.swift
│       └── MockSummarizer.swift
├── MemSearchSQLite/
│   ├── SQLiteVectorStore.swift          # final class : Sendable
│   ├── SQLiteSchema.swift               # GRDB migrations
│   ├── SQLiteHybridSearch.swift         # single-tx pool.read body
│   └── SQLiteRowCoding.swift            # Chunk <-> Row encode/decode
├── MemSearchEmbeddersHTTP/
│   ├── OpenAIEmbedder.swift
│   ├── OpenAIWire.swift                 # Codable DTOs
│   └── HTTPCancellation.swift           # URLError(.cancelled) translation helper
└── SQLiteVec/                           # vendored, static-link
    ├── module.modulemap
    ├── include/sqlite-vec.h             # rendered from upstream template, v0.1.9 substitutions
    └── sqlite-vec.c                     # upstream v0.1.9, unmodified
Tests/
├── MemSearchTests/
│   ├── ChunkIDStabilityTests.swift
│   ├── EmbeddingTests.swift
│   ├── ChunkerTests.swift
│   ├── ChunkerGoldenTests.swift
│   ├── RRFTests.swift
│   ├── ScannerTests.swift
│   ├── ErrorLiftingTests.swift
│   ├── EngineSearchTests.swift
│   ├── EngineIndexStreamTests.swift
│   ├── EngineReduceInvariantTests.swift
│   ├── EngineCancellationTests.swift
│   ├── SendableCompileGateTests.swift
│   └── EngineStubsTests.swift
├── MemSearchSQLiteTests/
│   ├── SchemaMigrationTests.swift
│   ├── CRUDTests.swift
│   ├── HybridSearchTests.swift
│   ├── ScanSmokeTests.swift
│   └── SummarySnapshotTests.swift
└── MemSearchEmbeddersHTTPTests/
    ├── OpenAIWireTests.swift
    └── OpenAICancellationTests.swift
```

### CLI package (sibling)

```
cli/
├── Package.swift                                              # depends on .package(path: "..")
├── Sources/memsearch/
│   ├── main.swift                                             # AsyncParsableCommand
│   ├── Subcommands/
│   │   ├── IndexCommand.swift
│   │   ├── SearchCommand.swift
│   │   └── InfoCommand.swift
│   ├── Config/
│   │   ├── ResolvedConfig.swift
│   │   ├── ConfigLoader.swift                                # JSON in v1; YAML/TOML add-on later
│   │   └── EnvResolver.swift
│   └── Dispatch/
│       └── BackendDispatch.swift                              # 1 case for MVP (sqlite × openai)
└── Tests/MemSearchCLITests/
    ├── ResolvedConfigTests.swift
    ├── ConfigLoaderTests.swift
    └── JSONOutputTests.swift
```

### Repo files modified

- `Package.swift` — rewritten from the placeholder.
- `Sources/Memsearch/Memsearch.swift` — deleted (placeholder).

### Repo files created (outside source)

- `docs/superpowers/phases/phase-1-notes.md` — Task 32.
- `tests/fixtures/python-baseline/python-top5.json`, `.sha256`, `manifest.json` — Task 1 (closing Phase 0 deferral).

---

## Task 1: Phase 1 entry — close Phase 0 deferrals

**Goal:** Resolve the three Phase 0 deferrals before any code lands: pin the Python ground-truth fixture, decide sqlite-vec hosting (vendor vs fork), re-grep the design spec for coherence.

**Files:**

- Create: `tests/fixtures/python-baseline/python-top5.json`, `.sha256`, `manifest.json`.
- Create (notes): `docs/superpowers/phases/phase-1-notes.md` (initialize; Task 32 finalizes it).

- [ ] **Step 1: Confirm allowlists for `cdn-lfs.huggingface.co` and `cas-server.xethub.hf.co`**

The Phase 0 deferral was network-blocked — the ONNX bge-m3 weights live on those hosts. Run:

```bash
curl -sI -o /dev/null -w "%{http_code}\n" https://cdn-lfs.huggingface.co
curl -sI -o /dev/null -w "%{http_code}\n" https://cas-server.xethub.hf.co
```

Expected: both return a non-403 HTTP code (200/302/404 are fine — anything that isn't a proxy block). If either is still blocked, **stop and request allowlisting**; do not falsify the fixture.

- [ ] **Step 2: Install Python ONNX provider into the local venv**

```bash
cd /Users/ronny/rdev/memsearch
uv sync --extra onnx
uv run memsearch --version
```

Expected: `--version` prints without error and `onnxruntime` resolves on first ingest call.

- [ ] **Step 3: Index the corpus with the Python ONNX provider**

```bash
COLL=memsearch_swift_baseline_phase1
uv run memsearch index \
    --paths tests/fixtures/python-baseline/corpus \
    --collection "$COLL" \
    --provider onnx \
    --model bge-m3 \
    --force
```

Expected: indexing reports a chunk count > 0 and no errors.

- [ ] **Step 4: Dump top-5 to `python-top5.json`**

```bash
cat > /tmp/dump_top5.py <<'PY'
import json, subprocess, pathlib

queries_path = pathlib.Path("tests/fixtures/python-baseline/queries.json")
out_path = pathlib.Path("tests/fixtures/python-baseline/python-top5.json")
queries = json.loads(queries_path.read_text())

result = {"results": []}
for q in queries["queries"]:
    proc = subprocess.run(
        ["uv", "run", "memsearch", "search", q,
         "-k", str(queries["topK"]),
         "--collection", "memsearch_swift_baseline_phase1",
         "--provider", "onnx",
         "--model", "bge-m3",
         "--json"],
        capture_output=True, text=True, check=True,
    )
    hits = json.loads(proc.stdout)
    minimal_hits = [
        {
            "chunk_id": h["chunk_id"],
            "source": h["source"],
            "heading": h.get("heading", ""),
            "start_line": h["start_line"],
            "end_line": h["end_line"],
            "score": h["score"],
        }
        for h in hits["hits"]
    ]
    result["results"].append({"query": q, "top": minimal_hits})

out_path.write_text(json.dumps(result, indent=2, sort_keys=True))
print(f"Wrote {len(result['results'])} query results to {out_path}")
PY

uv run python /tmp/dump_top5.py
jq '.results | length' tests/fixtures/python-baseline/python-top5.json
```

Expected: the `jq` count equals the number of queries in `queries.json` (8 at fixture-pin time).

- [ ] **Step 5: SHA-256 the top-5 file**

```bash
cd tests/fixtures/python-baseline
shasum -a 256 python-top5.json | awk '{print $1}' > python-top5.json.sha256
cat python-top5.json.sha256
```

Future re-runs hash the JSON and compare; any drift is detected here.

- [ ] **Step 6: Capture pip freeze + write the manifest**

```bash
uv pip freeze > /tmp/pip-freeze-snapshot.txt
```

Create `tests/fixtures/python-baseline/manifest.json`:

```json
{
  "fixture_version": 1,
  "date": "2026-05-21",
  "python": {
    "version": "<output of `python --version` minus the 'Python ' prefix>",
    "memsearch_version": "<output of `uv run memsearch --version` if exposed; else `git rev-parse HEAD`>"
  },
  "embedder": {
    "provider": "onnx",
    "model": "bge-m3",
    "dimension": 1024,
    "batch_size": "default",
    "extra_kwargs": {}
  },
  "chunker": {
    "max_chunk_size": 1500,
    "overlap_lines": 2,
    "heading_split": true,
    "content_hash": "sha256(content).hexdigest()[:16]",
    "chunk_id": "sha256('markdown:{source}:{start_line}:{end_line}:{content_hash}:{model}').hexdigest()[:16]",
    "comment": "Phase 1's Swift Chunker mirrors these defaults byte-for-byte."
  },
  "corpus": {
    "path": "corpus/",
    "file_count": "<output of `ls corpus | wc -l`>"
  },
  "queries": { "path": "queries.json", "topK": 5, "count": 8 },
  "results": { "path": "python-top5.json", "sha256_path": "python-top5.json.sha256" },
  "python_pip_freeze": [
    "<paste each line of /tmp/pip-freeze-snapshot.txt as a string element>"
  ]
}
```

Validate it parses:

```bash
jq . tests/fixtures/python-baseline/manifest.json > /dev/null
```

- [ ] **Step 7: Decide sqlite-vec hosting (vendor vs fork)**

Per `phase-0-notes.md`, the choice is between (a) public fork of `asg017/sqlite-vec` with a Package.swift PR, or (b) vendor the C source under `Sources/SQLiteVec/`. **Default to (b) for Phase 1** — vendoring is faster, removes external dependency on PR merge, and lets the implementer iterate. Record the decision in `phase-1-notes.md`:

```bash
mkdir -p docs/superpowers/phases
cat > docs/superpowers/phases/phase-1-notes.md <<'NOTE'
# Phase 1 — Notes (in progress)

**Period:** 2026-05-21 → <end date>
**Status:** in progress

## Decisions

- **sqlite-vec hosting:** vendor under `Sources/SQLiteVec/`. Source pinned to upstream v0.1.9 (commit `e9f598a`). Header rendered locally from `sqlite-vec.h.tmpl` with the v0.1.9 version substitutions. Static-link via `-DSQLITE_CORE -DSQLITE_VEC_STATIC`; consumer calls `sqlite3_vec_init` directly. Public-fork upstream is deferred (post-Phase 7) — vendoring removes the wait.
- **iOS-Simulator compile-gate canonical command:** `xcodebuild build -scheme <Product> -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/derived` (per-product). Recorded in Task 5.

## Surprises

(filled during Phase 1)

## Spec deltas applied

(filled during Phase 1)

## Items deferred to later phases

(filled during Phase 1)
NOTE
```

- [ ] **Step 8: Re-grep the design spec for Phase-0 patch coherence**

```bash
SPEC=docs/superpowers/specs/2026-05-20-swift-rewrite-design.md
grep -cF 'case unimplemented(String)' "$SPEC"
grep -cF 'case singleFlightViolation(any Error & Sendable)' "$SPEC"
grep -cF '`LanguageModelSession.Error`' "$SPEC"
grep -cF 'try Task.checkCancellation()' "$SPEC"
grep -cF 'compile-only verified in v1' "$SPEC"
grep -cF 'v1 status' "$SPEC"
grep -cF 'latencyPerBatch: Duration?' "$SPEC"
awk '/private func callRespond/,/^    }/' "$SPEC" | grep -c 'catch let e as'
```

Every line non-zero (last line ≥ 1; the macOS-26 example uses one typed catch + one untyped catch, so a count of 1 here is acceptable — see spec lines 631–650 where the second handler is `catch let e` with an `if #available` cast inside).

- [ ] **Step 9: Commit the fixture and the notes initializer**

```bash
git add tests/fixtures/python-baseline/python-top5.json \
        tests/fixtures/python-baseline/python-top5.json.sha256 \
        tests/fixtures/python-baseline/manifest.json \
        docs/superpowers/phases/phase-1-notes.md
git commit -m "test: pin Python ground-truth top-5 fixture (close Phase 0 deferral)"
```

---

## Task 2: Bootstrap multi-target SwiftPM layout

**Goal:** Replace the placeholder `Package.swift` with the real four-product layout. Declare `platforms:` for v1. Add deps. Stub every target's source directory so SwiftPM resolves before code lands.

**Files:**

- Modify: `Package.swift`.
- Delete: `Sources/Memsearch/Memsearch.swift` (placeholder).
- Create: empty `Sources/MemSearch/MemSearch.swift` placeholder (one-line `// MemSearch`), `Sources/MemSearchSQLite/_Module.swift`, `Sources/MemSearchEmbeddersHTTP/_Module.swift`. (`Sources/SQLiteVec/` is set up in Task 3.)
- Create: empty `Tests/MemSearchTests/_Module.swift`, `Tests/MemSearchSQLiteTests/_Module.swift`, `Tests/MemSearchEmbeddersHTTPTests/_Module.swift`.

- [ ] **Step 1: Rewrite `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let phase1Settings: [SwiftSetting] = [
    .enableUpcomingFeature("ApproachableConcurrency"),
]

let package = Package(
    name: "MemSearch",
    platforms: [.macOS(.v14), .iOS(.v17), .visionOS(.v1)],
    products: [
        .library(name: "MemSearch",                 targets: ["MemSearch"]),
        .library(name: "MemSearchSQLite",           targets: ["MemSearchSQLite"]),
        .library(name: "MemSearchEmbeddersHTTP",    targets: ["MemSearchEmbeddersHTTP"]),
        .library(name: "SQLiteVec",                 targets: ["SQLiteVec"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // --- C wrapper for sqlite-vec (vendored, static-link).
        .target(
            name: "SQLiteVec",
            path: "Sources/SQLiteVec",
            publicHeadersPath: "include",
            cSettings: [
                .define("SQLITE_CORE"),
                .define("SQLITE_VEC_STATIC"),
                .unsafeFlags(["-w"]),    // suppress 123 upstream warnings (Spike 0a note)
            ]
        ),

        // --- Library: engine + types + protocols + chunker + RRF + mocks.
        .target(
            name: "MemSearch",
            swiftSettings: phase1Settings
        ),

        // --- Library: SQLite-backed VectorStore.
        .target(
            name: "MemSearchSQLite",
            dependencies: [
                "MemSearch",
                "SQLiteVec",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: phase1Settings
        ),

        // --- Library: HTTP embedders. Phase 1 ships OpenAIEmbedder only.
        .target(
            name: "MemSearchEmbeddersHTTP",
            dependencies: ["MemSearch"],
            swiftSettings: phase1Settings
        ),

        // --- Tests.
        .testTarget(
            name: "MemSearchTests",
            dependencies: ["MemSearch"],
            swiftSettings: phase1Settings
        ),
        .testTarget(
            name: "MemSearchSQLiteTests",
            dependencies: ["MemSearch", "MemSearchSQLite"],
            swiftSettings: phase1Settings
        ),
        .testTarget(
            name: "MemSearchEmbeddersHTTPTests",
            dependencies: ["MemSearch", "MemSearchEmbeddersHTTP"],
            swiftSettings: phase1Settings
        ),
    ],
    swiftLanguageModes: [.v6]
)
```

`tools-version: 6.0` is the floor (the design spec's "ships against 6.0 toolchain"). The placeholder used `6.4`; we're tightening the floor.

- [ ] **Step 2: Remove the placeholder source**

```bash
rm Sources/Memsearch/Memsearch.swift
rmdir Sources/Memsearch
```

- [ ] **Step 3: Create stub `_Module.swift` files**

For each new target, drop a one-line marker so SwiftPM resolves:

```bash
mkdir -p Sources/MemSearch Sources/MemSearchSQLite Sources/MemSearchEmbeddersHTTP \
         Tests/MemSearchTests Tests/MemSearchSQLiteTests Tests/MemSearchEmbeddersHTTPTests

for t in MemSearch MemSearchSQLite MemSearchEmbeddersHTTP; do
  printf '// %s\n' "$t" > "Sources/$t/_Module.swift"
done
for t in MemSearchTests MemSearchSQLiteTests MemSearchEmbeddersHTTPTests; do
  printf '// %s\n' "$t" > "Tests/$t/_Module.swift"
done
```

(These markers are deleted in later tasks as real files land.)

- [ ] **Step 4: Resolve dependencies**

```bash
swift package resolve
cat Package.resolved | grep -A3 GRDB
```

Expected: `GRDB.swift` resolves to `7.x.y` (Spike 0a locked 7.10.0 — accept whatever 7.x is current).

- [ ] **Step 5: Compile (will fail because SQLiteVec sources don't exist yet — that's Task 3)**

```bash
swift build 2>&1 | head -20
```

Expected: failure mentions `Sources/SQLiteVec` is empty. Task 3 fills that in. Don't fix here.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/ Tests/
git commit -m "build: bootstrap multi-product SwiftPM layout (Phase 1)"
```

---

## Task 3: Vendor sqlite-vec C wrapper

**Goal:** Drop in `asg017/sqlite-vec` v0.1.9 source as a SwiftPM C target. Match Spike 0a's working shape exactly: `sqlite-vec.c` (upstream, unmodified) + `sqlite-vec.h` (rendered from upstream's `.h.tmpl` with v0.1.9 substitutions) + module map exposing the C symbols to Swift.

**Files:**

- Create: `Sources/SQLiteVec/sqlite-vec.c`
- Create: `Sources/SQLiteVec/include/sqlite-vec.h`
- Create: `Sources/SQLiteVec/module.modulemap`

- [ ] **Step 1: Fetch upstream v0.1.9**

```bash
cd /tmp
git clone --depth 1 --branch v0.1.9 https://github.com/asg017/sqlite-vec.git sqlite-vec-v0.1.9
ls /tmp/sqlite-vec-v0.1.9/sqlite-vec.c /tmp/sqlite-vec-v0.1.9/sqlite-vec.h.tmpl
```

Expected: both files exist.

- [ ] **Step 2: Render the header**

```bash
cd /Users/ronny/rdev/memsearch
mkdir -p Sources/SQLiteVec/include
sed \
  -e 's/${VERSION}/0.1.9/g' \
  -e 's/${VERSION_MAJOR}/0/g' \
  -e 's/${VERSION_MINOR}/1/g' \
  -e 's/${VERSION_PATCH}/9/g' \
  /tmp/sqlite-vec-v0.1.9/sqlite-vec.h.tmpl \
  > Sources/SQLiteVec/include/sqlite-vec.h
```

Verify the output:

```bash
grep -F 'SQLITE_VEC_VERSION ' Sources/SQLiteVec/include/sqlite-vec.h
```

Expected: a `#define SQLITE_VEC_VERSION "v0.1.9"` line (or similar — check upstream template for the literal).

- [ ] **Step 3: Copy `sqlite-vec.c`**

```bash
cp /tmp/sqlite-vec-v0.1.9/sqlite-vec.c Sources/SQLiteVec/sqlite-vec.c
```

- [ ] **Step 4: Write the module map**

Create `Sources/SQLiteVec/module.modulemap`:

```
module SQLiteVec {
    header "include/sqlite-vec.h"
    link "sqlite3"
    export *
}
```

The `link "sqlite3"` directive ensures the system SQLite library is linked for the `sqlite3_*` symbols `sqlite-vec.c` uses.

- [ ] **Step 5: Build to confirm**

```bash
swift build --target SQLiteVec 2>&1 | tail -20
```

Expected: build succeeds (warnings suppressed by `-w` in `Package.swift`).

- [ ] **Step 6: Smoke-link from a tiny Swift file**

Add a temporary file `Sources/MemSearchSQLite/_LinkSmoke.swift`:

```swift
import SQLiteVec
import SQLite3

@inline(__always)
package func _smokeLinkSqliteVec() {
    // Reference the symbol so the linker proves it resolves.
    var unused: @convention(c) (
        OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
        UnsafePointer<sqlite3_api_routines>?
    ) -> Int32 = sqlite3_vec_init
    _ = unused
}
```

Build:

```bash
swift build --target MemSearchSQLite 2>&1 | tail -10
```

Expected: succeeds. The `_LinkSmoke.swift` file gets deleted in Task 21 once the real `SQLiteVectorStore` references the symbol from production code.

- [ ] **Step 7: Commit**

```bash
git add Sources/SQLiteVec/ Sources/MemSearchSQLite/_LinkSmoke.swift
git commit -m "build: vendor sqlite-vec v0.1.9 as static-link C target"
```

---

## Task 4: Bootstrap CLI package + iOS-Simulator compile-gate

**Goal:** Stand up the sibling `MemSearch-CLI` SPM package (so `swift run memsearch` works at the end of Phase 1). Pin the canonical iOS-Simulator compile-gate command in `phase-1-notes.md`. The CLI itself stays mostly empty until Tasks 25–29.

**Files:**

- Create: `cli/Package.swift`
- Create: `cli/Sources/memsearch/main.swift` (one-line stub)
- Modify: `docs/superpowers/phases/phase-1-notes.md` (record the canonical compile-gate command)

- [ ] **Step 1: Scaffold the CLI package**

```bash
mkdir -p cli/Sources/memsearch cli/Tests/MemSearchCLITests
```

Create `cli/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemSearch-CLI",
    platforms: [.macOS(.v14)],   // macOS-only per spec; iOS hosts construct programmatically
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        // Config files use JSON via Foundation — no external dep needed.
        // Future: YAML / TOML loaders plug in behind `ConfigLoader`'s
        // file-extension dispatch without touching `ResolvedConfig`.
    ],
    targets: [
        .executableTarget(
            name: "memsearch",
            dependencies: [
                .product(name: "MemSearch",                 package: "MemSearch"),
                .product(name: "MemSearchSQLite",           package: "MemSearch"),
                .product(name: "MemSearchEmbeddersHTTP",    package: "MemSearch"),
                .product(name: "ArgumentParser",            package: "swift-argument-parser"),
            ],
            swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]
        ),
        .testTarget(
            name: "MemSearchCLITests",
            dependencies: ["memsearch"],
            swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
```

The config schema is a `Codable` value type loaded with `JSONDecoder`. Adding YAML or TOML in a later phase means a new case in `ConfigLoader.load(at:)` plus a single dependency declaration here — the rest of the resolver is format-agnostic.

- [ ] **Step 2: Stub `main.swift`**

```swift
// cli/Sources/memsearch/main.swift
import ArgumentParser

@main
struct Memsearch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "memsearch",
        abstract: "Semantic memory search",
        subcommands: []  // Tasks 25–29 register IndexCommand / SearchCommand / InfoCommand
    )
}
```

```bash
printf '// MemSearchCLITests placeholder — populated in Tasks 25+\n' \
  > cli/Tests/MemSearchCLITests/_Module.swift
```

- [ ] **Step 3: Resolve + build the CLI package**

```bash
cd cli
swift package resolve
swift build
cd ..
```

Expected: builds cleanly.

- [ ] **Step 4: Pin the iOS-Simulator compile-gate command in notes**

Append to `docs/superpowers/phases/phase-1-notes.md`:

```markdown
## iOS-Simulator compile-gate (canonical command)

For each iOS-required library product (`MemSearch`, `MemSearchSQLite`, `MemSearchEmbeddersHTTP`):

```bash
xcodebuild build \
    -scheme <ProductName> \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath /tmp/derived
```

SwiftPM auto-generates one scheme per library product. The CLI executable scheme (`memsearch`) is **excluded** from this gate — the CLI is macOS-only by design.

The `SQLiteVec` C product is iOS-required (transitively via `MemSearchSQLite`); SwiftPM links it through the dependent product, so explicitly building `MemSearchSQLite` covers it.
```

- [ ] **Step 5: Smoke-test the gate against the empty stubs**

```bash
xcodebuild build -scheme MemSearch -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/derived 2>&1 | tail -5
xcodebuild build -scheme MemSearchSQLite -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/derived 2>&1 | tail -5
xcodebuild build -scheme MemSearchEmbeddersHTTP -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/derived 2>&1 | tail -5
```

Expected: each prints `** BUILD SUCCEEDED **`. If any fails, fix before continuing — every later phase depends on this gate.

- [ ] **Step 6: Commit**

```bash
git add cli/ docs/superpowers/phases/phase-1-notes.md
git commit -m "build: bootstrap CLI package + pin iOS-Simulator compile-gate"
```

---

## Task 5: Core value types — `ChunkID`, `Chunk`, `Embedding` (with TDD ChunkID stability)

**Goal:** Stand up the three load-bearing value types. TDD `ChunkID` against the Python reference format so Phase 1's chunker stays cross-check-compatible from line one.

**Files:**

- Create: `Sources/MemSearch/Models/ChunkID.swift`, `Chunk.swift`, `Embedding.swift`.
- Create: `Tests/MemSearchTests/ChunkIDStabilityTests.swift`, `EmbeddingTests.swift`.
- Delete: `Sources/MemSearch/_Module.swift`, `Tests/MemSearchTests/_Module.swift` (replaced by real files).

- [ ] **Step 1: Compute the expected ChunkID with Python**

```bash
python3 -c "import hashlib; raw = b'markdown:test.md:1:10:abc1234567890def:openai-3-small'; print(hashlib.sha256(raw).hexdigest()[:16])"
```

Record the hex output (16 chars). Embed it as the expected value in the test below — substitute `<EXPECTED_ID>` with the printed string.

- [ ] **Step 2: Write the failing ChunkID stability test**

`Tests/MemSearchTests/ChunkIDStabilityTests.swift`:

```swift
import Testing
@testable import MemSearch

@Suite("ChunkID stability")
struct ChunkIDStabilityTests {

    @Test("compute(source:start:end:contentHash:model:) matches Python reference")
    func matchesPython() {
        // Reference computed by:
        //   python3 -c "import hashlib; raw = b'markdown:test.md:1:10:abc1234567890def:openai-3-small'; print(hashlib.sha256(raw).hexdigest()[:16])"
        let id = ChunkID.compute(
            source: "test.md",
            startLine: 1,
            endLine: 10,
            contentHash: "abc1234567890def",
            model: "openai-3-small"
        )
        #expect(id.rawValue == "<EXPECTED_ID>")   // substitute with Step 1 output
    }

    @Test("contentHash uses sha256(content).prefix(16)")
    func contentHashShape() {
        let h = ChunkID.contentHash(for: "hello world")
        #expect(h.count == 16)
        #expect(h.allSatisfy { $0.isHexDigit })
        // Reference: python3 -c "import hashlib; print(hashlib.sha256(b'hello world').hexdigest()[:16])"
        #expect(h == "b94d27b9934d3e08")
    }
}
```

Run:

```bash
swift test --filter ChunkIDStabilityTests
```

Expected: fails (`ChunkID.compute` doesn't exist yet).

- [ ] **Step 3: Implement `ChunkID`**

`Sources/MemSearch/Models/ChunkID.swift`:

```swift
import Foundation
import CryptoKit

public struct ChunkID: Hashable, Sendable {
    public let rawValue: String

    /// Mints a ChunkID. `package` so only the chunker (and tests) can call it.
    package init(_ rawValue: String) { self.rawValue = rawValue }
}

extension ChunkID {
    /// Composite ID matching `src/memsearch/chunker.py::compute_chunk_id`.
    /// `sha256("markdown:{source}:{start}:{end}:{contentHash}:{model}").hexdigest()[:16]`
    package static func compute(
        source: String,
        startLine: Int,
        endLine: Int,
        contentHash: String,
        model: String
    ) -> ChunkID {
        let raw = "markdown:\(source):\(startLine):\(endLine):\(contentHash):\(model)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return ChunkID(String(hex.prefix(16)))
    }

    /// `sha256(content).hexdigest()[:16]` — matches Python `Chunk.__post_init__`.
    package static func contentHash(for content: String) -> String {
        let digest = SHA256.hash(data: Data(content.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }
}
```

- [ ] **Step 4: Re-run the test, expect green**

```bash
swift test --filter ChunkIDStabilityTests
```

Expected: PASS.

- [ ] **Step 5: Implement `Chunk` and `Embedding`**

`Sources/MemSearch/Models/Chunk.swift`:

```swift
import Foundation

public struct Chunk: Sendable, Hashable {
    public let id: ChunkID
    public let source: URL
    public let heading: String
    public let headingLevel: Int
    public let startLine: Int
    public let endLine: Int
    public let content: String
    public let contentHash: String

    public init(
        id: ChunkID,
        source: URL,
        heading: String,
        headingLevel: Int,
        startLine: Int,
        endLine: Int,
        content: String,
        contentHash: String
    ) {
        self.id = id
        self.source = source
        self.heading = heading
        self.headingLevel = headingLevel
        self.startLine = startLine
        self.endLine = endLine
        self.content = content
        self.contentHash = contentHash
    }
}
```

`Sources/MemSearch/Models/Embedding.swift`:

```swift
public struct Embedding: Sendable {
    public let values: [Float]
    public var dimension: Int { values.count }

    /// - Postcondition: `values.count == expectedDimension`.
    public init(values: [Float], expectedDimension: Int) throws(EmbeddingError) {
        guard values.count == expectedDimension else {
            throw .dimensionMismatch(expected: expectedDimension, got: values.count)
        }
        self.values = values
    }
}
// NOT Hashable — [Float] hashing has NaN reflexivity hazards and large
// vectors are expensive to hash. See spec line 154.
```

`EmbeddingError` is referenced; Task 7 stands it up. To make this file compile in isolation, add a temporary marker stanza inside `Sources/MemSearch/Errors/EmbeddingError.swift`:

```swift
public enum EmbeddingError: Error, Sendable {
    case dimensionMismatch(expected: Int, got: Int)
}
```

The full enum definition lands in Task 7.

- [ ] **Step 6: Add `EmbeddingTests`**

`Tests/MemSearchTests/EmbeddingTests.swift`:

```swift
import Testing
@testable import MemSearch

@Suite("Embedding")
struct EmbeddingTests {

    @Test("init throws on dimension mismatch")
    func dimensionMismatch() {
        #expect(throws: EmbeddingError.self) {
            _ = try Embedding(values: [1, 2, 3], expectedDimension: 4)
        }
    }

    @Test("init succeeds when count matches")
    func dimensionMatches() throws {
        let e = try Embedding(values: [1, 2, 3, 4], expectedDimension: 4)
        #expect(e.dimension == 4)
        #expect(e.values == [1, 2, 3, 4])
    }
}
```

```bash
swift test --filter ChunkIDStabilityTests --filter EmbeddingTests
```

Expected: PASS.

- [ ] **Step 7: Clean up the stubs**

```bash
rm Sources/MemSearch/_Module.swift Tests/MemSearchTests/_Module.swift
```

- [ ] **Step 8: Commit**

```bash
git add Sources/MemSearch/Models/ChunkID.swift \
        Sources/MemSearch/Models/Chunk.swift \
        Sources/MemSearch/Models/Embedding.swift \
        Sources/MemSearch/Errors/EmbeddingError.swift \
        Tests/MemSearchTests/ChunkIDStabilityTests.swift \
        Tests/MemSearchTests/EmbeddingTests.swift
git rm Sources/MemSearch/_Module.swift Tests/MemSearchTests/_Module.swift
git commit -m "feat(MemSearch): ChunkID + Chunk + Embedding (TDD ChunkID stability)"
```

---

## Task 6: Remaining model types

**Goal:** Land every other Sendable value type the engine references. No business logic — these are purely data carriers. Test-after.

**Files (all in `Sources/MemSearch/Models/`):**

- Create: `StoredChunk.swift`, `SearchHit.swift`, `HybridQuery.swift`, `SourceFilter.swift`, `IndexStats.swift`, `ChunkingPolicy.swift`, `IndexEvent.swift`, `IndexFileError.swift`, `CompactedSummary.swift`, `EngineSummary.swift`.

- [ ] **Step 1: Write each type per the design spec**

Match the design spec verbatim (spec lines 157–210, 305–313). Each type is a `public struct` (or `public enum` for `IndexEvent` / `IndexFileError`) and is `Sendable`.

Key shapes (refer to spec for full bodies — code-complete from the spec, no surprises):

```swift
// StoredChunk.swift
public struct StoredChunk: Sendable {
    public let chunk: Chunk
    public let embedding: Embedding
    public init(chunk: Chunk, embedding: Embedding) { self.chunk = chunk; self.embedding = embedding }
}

// SearchHit.swift — Hashable
public struct SearchHit: Sendable, Hashable {
    public let chunk: Chunk
    public let score: Float
    public let denseScore: Float?
    public let bm25Score: Float?
    public init(chunk: Chunk, score: Float, denseScore: Float?, bm25Score: Float?) { ... }
}

// HybridQuery.swift
public struct HybridQuery: Sendable {
    public let queryText: String
    public let queryEmbedding: Embedding
    public let topK: Int
    public let filter: SourceFilter?
    public let rrfK: Int
    public init(queryText: String, queryEmbedding: Embedding, topK: Int, filter: SourceFilter?, rrfK: Int = 60) { ... }
}

// SourceFilter.swift
public struct SourceFilter: Sendable {
    public let prefix: URL
    public init(prefix: URL) { self.prefix = prefix }
}

// IndexStats.swift
public struct IndexStats: Sendable {
    public let filesScanned: Int
    public let chunksAdded: Int
    public let chunksRemoved: Int
    public let failedFiles: [URL]
    public init(filesScanned: Int, chunksAdded: Int, chunksRemoved: Int, failedFiles: [URL]) { ... }
}

// ChunkingPolicy.swift
public struct ChunkingPolicy: Sendable {
    public let maxChunkSize: Int
    public let overlapLines: Int
    public init(maxChunkSize: Int, overlapLines: Int) { ... }
    public static let `default` = ChunkingPolicy(maxChunkSize: 1500, overlapLines: 2)
}

// IndexEvent.swift
public enum IndexEvent: Sendable {
    case indexed(URL, added: Int, removed: Int)
    case removed(URL, chunkCount: Int)
    case failed(URL, IndexFileError)
}

// IndexFileError.swift
public enum IndexFileError: Error, Sendable {
    case embedding(EmbeddingError)
    case store(VectorStoreError)
    case scan(any Error & Sendable)
    case chunking(any Error & Sendable)
}

// CompactedSummary.swift
public struct CompactedSummary: Sendable {
    public let markdown: String
    public let dateStamp: Date
    public let chunkCount: Int
    public init(markdown: String, dateStamp: Date, chunkCount: Int) { ... }

    /// "YYYY-MM-DD.md" derived from `dateStamp`. Uses Foundation's
    /// `Date.ISO8601FormatStyle` — locale-independent, UTC by default,
    /// no `DateFormatter`/`Locale`/`Calendar` setup required.
    public var proposedFilename: String {
        "\(dateStamp.formatted(.iso8601.year().month().day())).md"
    }
}

// EngineSummary.swift
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
```

`VectorStoreError` (referenced by `IndexFileError`) is added in Task 7 alongside the rest of the error stubs.

- [ ] **Step 2: Build**

```bash
swift build --target MemSearch
```

Expected: succeeds. (Some `VectorStoreError` references need a stub case; add `public enum VectorStoreError: Error, Sendable { case _todo }` in `Sources/MemSearch/Errors/VectorStoreError.swift` to unblock — Task 7 finishes it.)

- [ ] **Step 3: Commit**

```bash
git add Sources/MemSearch/Models/ Sources/MemSearch/Errors/VectorStoreError.swift
git commit -m "feat(MemSearch): remaining model types (StoredChunk, SearchHit, HybridQuery, …)"
```

---

## Task 7: Errors — `MemSearchError`, `EmbeddingError`, `VectorStoreError`, `LLMError` + `LocalizedError`

**Goal:** Finalize the four error enums per the design spec (lines 657–678 for LLMError, 959–987 for everything else). Add `LocalizedError` conformances so SwiftUI `.alert(...)` renders English messages out of the box.

**Files:**

- Modify: `Sources/MemSearch/Errors/EmbeddingError.swift`, `VectorStoreError.swift`.
- Create: `Sources/MemSearch/Errors/MemSearchError.swift`, `LLMError.swift`, `LocalizedDescriptions.swift`.

- [ ] **Step 1: Finalize `EmbeddingError`** per spec lines 972–979

```swift
public enum EmbeddingError: Error, Sendable {
    case authenticationFailed
    case rateLimited(retryAfter: Duration?)
    case dimensionMismatch(expected: Int, got: Int)
    case modelNotFound(String)
    case networkFailure(any Error & Sendable)
    case decodingFailed(any Error & Sendable)
}
```

- [ ] **Step 2: Finalize `VectorStoreError`** per spec lines 981–986

```swift
public enum VectorStoreError: Error, Sendable {
    case connectionFailed(any Error & Sendable)
    case schemaIncompatible(reason: String)
    case dimensionMismatch(expected: Int, got: Int)
    case backendError(any Error & Sendable)
}
```

- [ ] **Step 3: Write `LLMError`** per spec lines 657–676 (preserves the `singleFlightViolation` case from the Phase 0 patch)

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
    /// Surface for summarizers whose single-flight serialization was bypassed.
    /// Tests `#expect` zero occurrences. (Phase 6 implements summarizers.)
    case singleFlightViolation(any Error & Sendable)
}
```

- [ ] **Step 4: Write `MemSearchError`** per spec lines 959–970

```swift
import Foundation

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
```

- [ ] **Step 5: `LocalizedError` conformances**

`Sources/MemSearch/Errors/LocalizedDescriptions.swift`:

```swift
import Foundation

/// Renders any `Error` for end-user display: prefer `LocalizedError.errorDescription`,
/// then `NSError.localizedDescription`, finally fall back to `String(describing:)`.
/// `some Error` opens the existential at the call site (SE-0352) — no boxed
/// `any Error` argument, no extra existential dispatch.
private func describe(_ error: some Error) -> String {
    if let localized = (error as? LocalizedError)?.errorDescription { return localized }
    return (error as NSError).localizedDescription
}

private func describe(_ retryAfter: Duration?) -> String {
    guard let d = retryAfter else { return "soon" }
    return "\(d)"
}

extension MemSearchError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .embedding(let e):              "Embedding error: \(e.errorDescription ?? "\(e)")"
        case .store(let e):                  "Vector store error: \(e.errorDescription ?? "\(e)")"
        case .llm(let e):                    "LLM error: \(e.errorDescription ?? "\(e)")"
        case .scan(let url, let e):          "Failed to read \(url.path): \(describe(e))"
        case .chunking(let url, let e):      "Failed to chunk \(url.path): \(describe(e))"
        case .configurationInvalid(let m):   "Configuration invalid: \(m)"
        case .noSummarizerConfigured:        "No summarizer configured"
        case .unimplemented(let m):          "Not implemented: \(m)"
        }
    }
}

extension EmbeddingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .authenticationFailed:            "Embedding authentication failed"
        case .rateLimited(let retryAfter):     "Embedding rate-limited (retry after \(describe(retryAfter)))"
        case .dimensionMismatch(let e, let g): "Embedding dimension mismatch (expected \(e), got \(g))"
        case .modelNotFound(let name):         "Embedding model not found: \(name)"
        case .networkFailure(let e):           "Embedding network failure: \(describe(e))"
        case .decodingFailed(let e):           "Embedding response decoding failed: \(describe(e))"
        }
    }
}

extension VectorStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let e):            "Vector store connection failed: \(describe(e))"
        case .schemaIncompatible(let r):          "Vector store schema incompatible: \(r)"
        case .dimensionMismatch(let exp, let g):  "Vector store dimension mismatch (expected \(exp), got \(g))"
        case .backendError(let e):                "Vector store backend error: \(describe(e))"
        }
    }
}

extension LLMError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable:                  "LLM unavailable"
        case .authenticationFailed:         "LLM authentication failed"
        case .rateLimited(let retryAfter):  "LLM rate-limited (retry after \(describe(retryAfter)))"
        case .contextWindowExceeded:        "LLM context window exceeded"
        case .unsupportedLocale:            "LLM locale unsupported"
        case .networkFailure(let e):        "LLM network failure: \(describe(e))"
        case .invalidResponse:              "LLM invalid response"
        case .modelFailure(let e):          "LLM model failure: \(describe(e))"
        case .singleFlightViolation(let e): "LLM single-flight violation: \(describe(e))"
        }
    }
}
```

These messages render cleanly inside SwiftUI `.alert(isPresented:)` because every nested `any Error & Sendable` payload is unwrapped through `LocalizedError` first, then `NSError.localizedDescription`, with `String(describing:)` only as a last-resort fallback. `Duration?` in `rateLimited` is rendered without leaking `Optional(...)` syntax.

- [ ] **Step 6: Build**

```bash
swift build --target MemSearch
```

Expected: succeeds.

- [ ] **Step 7: Commit**

```bash
git add Sources/MemSearch/Errors/
git commit -m "feat(MemSearch): finalize error enums + LocalizedError"
```

---

## Task 8: Protocols — `VectorStore`, `EmbeddingProvider`, `LLMSummarizer`

**Goal:** Land the three protocols per spec lines 218–247. **No typed throws on protocol requirements.**

**Files:**

- Create: `Sources/MemSearch/Protocols/VectorStore.swift`, `EmbeddingProvider.swift`, `LLMSummarizer.swift`.

- [ ] **Step 1: Implement per the design spec verbatim**

`VectorStore.swift`:

```swift
import Foundation

public protocol VectorStore: Sendable {
    nonisolated var dimension: Int { get }

    func upsert(_ records: [StoredChunk]) async throws -> Int
    func hybridSearch(_ query: HybridQuery) async throws -> [SearchHit]

    /// Stream every chunk matching the optional filter. The stream's `Failure`
    /// is `any Error` (Swift 6.0 stdlib limitation; narrow when 6.1 is the floor).
    func scan(filter: SourceFilter?) -> AsyncThrowingStream<Chunk, any Error>

    func indexedSources() async throws -> Set<URL>
    func chunkIDs(forSource: URL) async throws -> Set<ChunkID>
    func delete(ids: [ChunkID]) async throws -> Int
    func delete(source: URL) async throws -> Int

    /// Snapshot-consistent counts in a single backend round-trip — must be
    /// computed inside one read transaction so concurrent writers cannot
    /// produce torn `(sources, chunks)` pairs. SQLite implements this as
    /// `SELECT COUNT(DISTINCT source), COUNT(*) FROM chunks_meta` inside
    /// `pool.read`. Loop-2 review surfaced that an N+1 engine-level loop
    /// over `indexedSources()` + `chunkIDs(forSource:)` raced concurrent
    /// `indexStream` calls; this protocol method removes the gap.
    func summary() async throws -> EngineSummary

    func close() async
}
```

> **Spec patch required.** This adds `summary() async throws -> EngineSummary` to `VectorStore`, which the design spec at lines 218–232 doesn't currently declare. Apply the patch to `docs/superpowers/specs/2026-05-20-swift-rewrite-design.md` in the same commit per the phasing doc's "Spec deltas applied" ritual.

`EmbeddingProvider.swift`:

```swift
public protocol EmbeddingProvider: Sendable {
    nonisolated var modelName: String { get }
    nonisolated var dimension: Int { get }

    /// - Postcondition on success: `result.count == texts.count` and
    ///   `result[i]` corresponds to `texts[i]`.
    /// - Throws: on first failure; partial success is not exposed.
    func embed(_ texts: [String]) async throws -> [Embedding]
}
```

`LLMSummarizer.swift`:

```swift
public protocol LLMSummarizer: Sendable {
    func summarize(prompt: String) async throws -> String
}
```

- [ ] **Step 2: Build + commit**

```bash
swift build --target MemSearch
git add Sources/MemSearch/Protocols/
git commit -m "feat(MemSearch): VectorStore + EmbeddingProvider + LLMSummarizer protocols"
```

---

## Task 9: Mocks — `MockEmbeddingProvider`, `MockVectorStore`, `MockSummarizer`

**Goal:** Land the package-visible mocks per spec lines 1015–1057. Content-keyed failure injection (deterministic across concurrent callers). `MockEmbeddingProvider` exposes `latencyPerBatch: Duration?` so cancellation tests have a documented suspension point. **No `@unchecked Sendable` or `nonisolated(unsafe)`** — otherwise the Sendable compile gate (Task 19) becomes theatre.

**Files:**

- Create: `Sources/MemSearch/Mocks/MockEmbeddingProvider.swift`, `MockVectorStore.swift`, `MockSummarizer.swift`.

- [ ] **Step 1: `MockEmbeddingProvider`** (final class : Sendable; OSAllocatedUnfairLock for state)

```swift
import Foundation
import CryptoKit
import os

package final class MockEmbeddingProvider: EmbeddingProvider {
    package nonisolated let modelName: String = "mock"
    package nonisolated let dimension: Int

    package struct State: Sendable {
        package var injectedFailures: [String: EmbeddingError] = [:]
        package var latencyPerBatch: Duration? = nil
        package var callCount: Int = 0
    }

    private let lock: OSAllocatedUnfairLock<State>

    package init(
        dimension: Int = 8,
        injectedFailures: [String: EmbeddingError] = [:],
        latencyPerBatch: Duration? = nil
    ) {
        self.dimension = dimension
        self.lock = OSAllocatedUnfairLock(initialState: .init(
            injectedFailures: injectedFailures,
            latencyPerBatch: latencyPerBatch,
            callCount: 0
        ))
    }

    package func embed(_ texts: [String]) async throws -> [Embedding] {
        // The lock is taken in short sections only — never held across the
        // `Task.sleep(for:)` await — so concurrent `embed` calls don't
        // serialize on it. `callCount` is bumped in a separate critical
        // section per call (interleaving across concurrent calls is fine for
        // a counter; tests only assert it from a sequential context).
        let (failures, latency) = lock.withLock { ($0.injectedFailures, $0.latencyPerBatch) }
        if let latency { try await Task.sleep(for: latency) }
        if let first = texts.first, let injected = failures[first] {
            lock.withLock { $0.callCount += 1 }
            throw injected
        }
        lock.withLock { $0.callCount += 1 }
        return try texts.map {
            try Embedding(values: hashToFloats($0, dim: dimension), expectedDimension: dimension)
        }
    }

    package var callCount: Int { lock.withLock { $0.callCount } }

    /// Deterministic seed from `s` via SHA-256.
    /// `Hasher` is process-randomized (different vectors across runs); we need
    /// run-stable output for golden tests + cross-checks. First 8 bytes of
    /// SHA-256(s) seed SplitMix64; clamped to non-zero (golden-ratio constant)
    /// since 0 is a fixed point of xor-shift family RNGs.
    private func hashToFloats(_ s: String, dim: Int) -> [Float] {
        let digest = SHA256.hash(data: Data(s.utf8))
        var seed: UInt64 = 0
        for byte in digest.prefix(8) { seed = (seed << 8) | UInt64(byte) }
        if seed == 0 { seed = 0x9E3779B97F4A7C15 }
        var rng = SplitMix64(state: seed)
        return (0..<dim).map { _ in Float.random(in: -1...1, using: &rng) }
    }
}

/// SplitMix64 — accepts any seed including 0 once shifted, no degenerate
/// fixed points. Reference: https://prng.di.unimi.it/splitmix64.c
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
```

- [ ] **Step 2: `MockVectorStore`** (actor; in-memory storage)

```swift
import Foundation

package actor MockVectorStore: VectorStore {
    package nonisolated let dimension: Int
    private var records: [ChunkID: StoredChunk] = [:]
    /// In-order log of `upsert` / `delete` calls — useful for assertions.
    package private(set) var operationLog: [String] = []
    /// Optional canned ranking returned by `hybridSearch` when set. `private`
    /// so callers must use the documented `setCannedHits(_:)` setter — the var
    /// itself is never mutated from outside.
    private var cannedHits: [SearchHit]?

    package init(dimension: Int = 8) {
        self.dimension = dimension
    }

    package func upsert(_ items: [StoredChunk]) async throws -> Int {
        // Mirror SQLiteVectorStore's contract: dimension mismatches throw before
        // any state changes. Without this, engine tests against the mock would
        // miss dimension-validation regressions that the SQLite backend catches.
        for item in items where item.embedding.dimension != dimension {
            throw VectorStoreError.dimensionMismatch(
                expected: dimension, got: item.embedding.dimension
            )
        }
        for item in items { records[item.chunk.id] = item }
        operationLog.append("upsert(\(items.count))")
        return items.count
    }

    package func hybridSearch(_ q: HybridQuery) async throws -> [SearchHit] {
        if let canned = cannedHits { return canned }
        // Fallback: dense-cosine over in-memory records, no BM25.
        let qVec = q.queryEmbedding.values
        let scored: [SearchHit] = records.values.map { rec in
            let v = rec.embedding.values
            let dot = zip(qVec, v).map(*).reduce(0, +)
            let nq = sqrt(qVec.map { $0 * $0 }.reduce(0, +))
            let nv = sqrt(v.map { $0 * $0 }.reduce(0, +))
            let cos = (nq > 0 && nv > 0) ? dot / (nq * nv) : 0
            return SearchHit(chunk: rec.chunk, score: cos, denseScore: cos, bm25Score: nil)
        }
        return Array(scored.sorted(by: { $0.score > $1.score }).prefix(q.topK))
    }

    package nonisolated func scan(filter: SourceFilter?) -> AsyncThrowingStream<Chunk, any Error> {
        AsyncThrowingStream { continuation in
            // Capture the inner Task so `onTermination` can cancel it when the
            // consumer drops the stream — without this, the unstructured Task
            // leaks until completion.
            let task = Task {
                do {
                    // Observe cancellation *before* the actor hop — without
                    // this, a cancelled consumer still pays the full snapshot
                    // cost before the per-yield checkCancellation kicks in.
                    try Task.checkCancellation()
                    let snapshot = await self.snapshotChunks(filter: filter)
                    for c in snapshot {
                        try Task.checkCancellation()
                        continuation.yield(c)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func snapshotChunks(filter: SourceFilter?) -> [Chunk] {
        records.values.map(\.chunk).filter { c in
            guard let f = filter else { return true }
            return c.source.path.hasPrefix(f.prefix.path)
        }
    }

    package func indexedSources() async throws -> Set<URL> {
        Set(records.values.map(\.chunk.source))
    }

    package func chunkIDs(forSource source: URL) async throws -> Set<ChunkID> {
        Set(records.values.filter { $0.chunk.source == source }.map(\.chunk.id))
    }

    package func delete(ids: [ChunkID]) async throws -> Int {
        var n = 0
        for id in ids where records.removeValue(forKey: id) != nil { n += 1 }
        operationLog.append("delete(ids: \(n))")
        return n
    }

    package func delete(source: URL) async throws -> Int {
        let toRemove = records.filter { $0.value.chunk.source == source }.map(\.key)
        for id in toRemove { records.removeValue(forKey: id) }
        operationLog.append("delete(source: \(toRemove.count))")
        return toRemove.count
    }

    package func close() async { /* no-op */ }

    package func setCannedHits(_ hits: [SearchHit]?) { self.cannedHits = hits }

    /// Snapshot inside a single actor turn — both reads see the same
    /// `records` dict instance, so the pair is torn-free by construction.
    package func summary() async throws -> EngineSummary {
        let sources = Set(records.values.map(\.chunk.source))
        return EngineSummary(sourceCount: sources.count, chunkCount: records.count)
    }
}
```

- [ ] **Step 3: `MockSummarizer`** (struct : Sendable)

```swift
package struct MockSummarizer: LLMSummarizer {
    package let canned: String
    package let injectedFailure: LLMError?

    package init(canned: String = "mock summary", injectedFailure: LLMError? = nil) {
        self.canned = canned
        self.injectedFailure = injectedFailure
    }

    package func summarize(prompt: String) async throws -> String {
        if let e = injectedFailure { throw e }
        return canned
    }
}
```

- [ ] **Step 4: Build + commit**

```bash
swift build --target MemSearch
git add Sources/MemSearch/Mocks/
git commit -m "feat(MemSearch): package-visible mocks (content-keyed injection + latency)"
```

---

## Task 10: Chunker (TDD)

**Goal:** Heading-split chunker that mirrors `src/memsearch/chunker.py` byte-for-byte for the fixture corpus. Golden-file tests anchor the format. Phase 1's success criterion 6 (≥60% top-3 overlap with Python top-5) depends on this.

**Files:**

- Create: `Sources/MemSearch/Chunker/Chunker.swift`.
- Create: `Tests/MemSearchTests/ChunkerTests.swift`, `ChunkerGoldenTests.swift`.
- Create: `Tests/MemSearchTests/Fixtures/chunker-input.md`, `chunker-expected.json` (golden).

- [ ] **Step 1: Capture the golden fixture from Python**

Pick a small representative markdown (e.g., `tests/fixtures/python-baseline/corpus/README.md__copy.md` if you copied README, else a hand-written 60-line file). Save it as `Tests/MemSearchTests/Fixtures/chunker-input.md`.

Run the Python chunker against it and serialize the result:

```bash
mkdir -p Tests/MemSearchTests/Fixtures
cat > /tmp/dump_chunks.py <<'PY'
import json, pathlib, sys
sys.path.insert(0, "src")
from memsearch.chunker import chunk_markdown, compute_chunk_id

text = pathlib.Path("Tests/MemSearchTests/Fixtures/chunker-input.md").read_text()
chunks = chunk_markdown(text, source="chunker-input.md", max_chunk_size=1500, overlap_lines=2)

out = []
for c in chunks:
    cid = compute_chunk_id(c.source, c.start_line, c.end_line, c.content_hash, "test-model")
    out.append({
        "id": cid,
        "source": c.source,
        "heading": c.heading,
        "headingLevel": c.heading_level,
        "startLine": c.start_line,
        "endLine": c.end_line,
        "contentHash": c.content_hash,
        "content": c.content,
    })
pathlib.Path("Tests/MemSearchTests/Fixtures/chunker-expected.json").write_text(
    json.dumps(out, indent=2, sort_keys=True)
)
print(f"Wrote {len(out)} chunks")
PY
uv run python /tmp/dump_chunks.py
```

- [ ] **Step 2: Write the failing golden test**

`Tests/MemSearchTests/ChunkerGoldenTests.swift`:

```swift
import Foundation
import Testing
@testable import MemSearch

@Suite("Chunker — golden fixture")
struct ChunkerGoldenTests {

    @Test("Swift output matches Python golden byte-for-byte")
    func goldenFixture() throws {
        let bundle = Bundle.module
        let inputURL = try #require(bundle.url(forResource: "chunker-input", withExtension: "md"))
        let expectedURL = try #require(bundle.url(forResource: "chunker-expected", withExtension: "json"))

        let text = try String(contentsOf: inputURL, encoding: .utf8)
        let actual = Chunker.chunk(
            text: text,
            source: URL(fileURLWithPath: "chunker-input.md"),
            policy: .default,
            embedderModelName: "test-model"
        )

        struct Expected: Decodable, Equatable {
            let id: String
            let source: String
            let heading: String
            let headingLevel: Int
            let startLine: Int
            let endLine: Int
            let contentHash: String
            let content: String
        }
        let expected = try JSONDecoder().decode([Expected].self, from: Data(contentsOf: expectedURL))

        #expect(actual.count == expected.count, "chunk count mismatch")
        for (a, e) in zip(actual, expected) {
            #expect(a.id.rawValue == e.id, "ChunkID mismatch at \(e.startLine)–\(e.endLine)")
            #expect(a.heading == e.heading)
            #expect(a.headingLevel == e.headingLevel)
            #expect(a.startLine == e.startLine)
            #expect(a.endLine == e.endLine)
            #expect(a.contentHash == e.contentHash)
            #expect(a.content == e.content)
        }
    }
}
```

To make the bundle resources visible, update the test target in `Package.swift`:

```swift
.testTarget(
    name: "MemSearchTests",
    dependencies: ["MemSearch"],
    resources: [.copy("Fixtures")],
    swiftSettings: phase1Settings
),
```

Run:

```bash
swift test --filter ChunkerGoldenTests
```

Expected: build fails (`Chunker` doesn't exist).

- [ ] **Step 3: Implement `Chunker`**

`Sources/MemSearch/Chunker/Chunker.swift`:

```swift
import Foundation

public enum Chunker {

    public static func chunk(
        text: String,
        source: URL,
        policy: ChunkingPolicy = .default,
        embedderModelName: String
    ) -> [Chunk] {
        let lines = text.components(separatedBy: "\n")
        let headings = findHeadings(in: lines)
        let sections = buildSections(lines: lines, headings: headings)

        var chunks: [Chunk] = []
        for s in sections {
            let sectionText = lines[s.start..<s.end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sectionText.isEmpty, hasMeaningfulContent(sectionText) else { continue }

            if sectionText.count <= policy.maxChunkSize {
                let startLine = s.start + 1
                let endLine = s.end
                chunks.append(makeChunk(
                    content: sectionText,
                    source: source,
                    heading: s.heading,
                    headingLevel: s.level,
                    startLine: startLine,
                    endLine: endLine,
                    embedderModelName: embedderModelName
                ))
            } else {
                let split = splitLargeSection(
                    lines: Array(lines[s.start..<s.end]),
                    source: source,
                    heading: s.heading,
                    headingLevel: s.level,
                    baseLine: s.start,
                    maxSize: policy.maxChunkSize,
                    overlap: policy.overlapLines,
                    embedderModelName: embedderModelName
                )
                chunks.append(contentsOf: split)
            }
        }
        return chunks
    }

    // MARK: - heading detection

    private struct Heading { let lineIdx: Int; let level: Int; let title: String }
    private struct Section { let start: Int; let end: Int; let heading: String; let level: Int }

    private static func findHeadings(in lines: [String]) -> [Heading] {
        var out: [Heading] = []
        for (i, line) in lines.enumerated() {
            // ^(#{1,6})\s+(.+)$
            guard let firstNonHash = line.firstIndex(where: { $0 != "#" }), firstNonHash != line.startIndex else { continue }
            let level = line.distance(from: line.startIndex, to: firstNonHash)
            guard level >= 1 && level <= 6, line[firstNonHash] == " " else { continue }
            let title = line[line.index(after: firstNonHash)...].trimmingCharacters(in: .whitespaces)
            out.append(Heading(lineIdx: i, level: level, title: String(title)))
        }
        return out
    }

    private static func buildSections(lines: [String], headings: [Heading]) -> [Section] {
        var out: [Section] = []
        if headings.isEmpty || headings[0].lineIdx > 0 {
            let end = headings.first?.lineIdx ?? lines.count
            out.append(Section(start: 0, end: end, heading: "", level: 0))
        }
        for (i, h) in headings.enumerated() {
            let next = (i + 1 < headings.count) ? headings[i + 1].lineIdx : lines.count
            out.append(Section(start: h.lineIdx, end: next, heading: h.title, level: h.level))
        }
        return out
    }

    private static func hasMeaningfulContent(_ text: String) -> Bool {
        let stripped = text.replacingOccurrences(of: #"<!--.*?-->"#, with: "", options: .regularExpression)
        let body = stripped.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                guard let firstNonHash = line.firstIndex(where: { $0 != "#" }) else { return true }
                if firstNonHash == line.startIndex { return true }
                let level = line.distance(from: line.startIndex, to: firstNonHash)
                return !(level >= 1 && level <= 6 && line[firstNonHash] == " ")
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body.count >= 2
    }

    private static func makeChunk(
        content: String,
        source: URL,
        heading: String,
        headingLevel: Int,
        startLine: Int,
        endLine: Int,
        embedderModelName: String
    ) -> Chunk {
        let contentHash = ChunkID.contentHash(for: content)
        let id = ChunkID.compute(
            source: source.lastPathComponent,
            startLine: startLine,
            endLine: endLine,
            contentHash: contentHash,
            model: embedderModelName
        )
        return Chunk(
            id: id,
            source: source,
            heading: heading,
            headingLevel: headingLevel,
            startLine: startLine,
            endLine: endLine,
            content: content,
            contentHash: contentHash
        )
    }

    private static func splitLargeSection(
        lines: [String],
        source: URL,
        heading: String,
        headingLevel: Int,
        baseLine: Int,
        maxSize: Int,
        overlap: Int,
        embedderModelName: String
    ) -> [Chunk] {
        // Mirror `_split_large_section` from chunker.py: prefer paragraph-boundary
        // splits, fall back to line-boundary splits with rollback, last resort
        // intra-line split. See chunker.py:145–270 for the algorithm.
        // ... (port the Python state machine line-for-line; keep the helper
        // names parallel: emit / emitBounded / paragraphBreak detection.)
        // The golden test in Step 2 catches every divergence.
        fatalError("Implementer ports `_split_large_section` from chunker.py here")
    }
}
```

The split-large-section helper is the longest port; mirror Python `chunker.py` lines 145–270. The golden test will catch every divergence — keep iterating until the test passes.

- [ ] **Step 4: Run the golden test until green**

```bash
swift test --filter ChunkerGoldenTests
```

Iterate the splitter until the JSON serialization matches byte-for-byte. The first few runs likely fail at the splitter; that's expected.

- [ ] **Step 5: Add a smaller `ChunkerTests` covering edge cases**

`Tests/MemSearchTests/ChunkerTests.swift`:

```swift
import Foundation
import Testing
@testable import MemSearch

@Suite("Chunker — edge cases")
struct ChunkerTests {

    @Test("empty input → no chunks")
    func empty() {
        #expect(Chunker.chunk(text: "", source: URL(fileURLWithPath: "x.md"), embedderModelName: "m").isEmpty)
    }

    @Test("preamble before first heading is its own chunk")
    func preamble() {
        let text = "intro line\n\n# H1\nbody"
        let out = Chunker.chunk(text: text, source: URL(fileURLWithPath: "x.md"), embedderModelName: "m")
        #expect(out.count == 2)
        #expect(out[0].heading == "")
        #expect(out[0].headingLevel == 0)
        #expect(out[1].heading == "H1")
        #expect(out[1].headingLevel == 1)
    }

    @Test("heading-only sections (no body) are dropped")
    func headingOnly() {
        let text = "# H1\n## H2\n## H3\nbody"
        let out = Chunker.chunk(text: text, source: URL(fileURLWithPath: "x.md"), embedderModelName: "m")
        #expect(out.count == 1)
        #expect(out[0].heading == "H3")
    }

    @Test("contentHash is sha256(content).prefix(16)")
    func contentHashShape() {
        let text = "# H1\nhello"
        let out = Chunker.chunk(text: text, source: URL(fileURLWithPath: "x.md"), embedderModelName: "m")
        #expect(out[0].contentHash == ChunkID.contentHash(for: out[0].content))
    }
}
```

- [ ] **Step 6: Commit**

```bash
git add Sources/MemSearch/Chunker/ \
        Tests/MemSearchTests/ChunkerTests.swift \
        Tests/MemSearchTests/ChunkerGoldenTests.swift \
        Tests/MemSearchTests/Fixtures/ \
        Package.swift
git commit -m "feat(MemSearch): heading-based Chunker (Python parity, golden-anchored)"
```

---

## Task 11: RRF.fuse helper (TDD)

**Goal:** Pure-math reciprocal rank fusion. Package-visible. Theoretical max = `numRetrievers / (k + 1)`; output scores normalized to `[0, 1]`. Spec lines 397–408.

**Files:**

- Create: `Sources/MemSearch/RRF/RRF.swift`, `Tests/MemSearchTests/RRFTests.swift`.

- [ ] **Step 1: Failing test**

```swift
import Testing
@testable import MemSearch

@Suite("RRF.fuse")
struct RRFTests {
    @Test("single retriever — top item normalized to 1.0")
    func singleRetriever() {
        let fused = RRF.fuse([[ChunkID("a"), ChunkID("b"), ChunkID("c")]], k: 60, topK: 3)
        #expect(fused.count == 3)
        #expect(fused[0].0 == ChunkID("a"))
        #expect(abs(fused[0].1 - 1.0) < 1e-6)
    }

    @Test("two retrievers — fused score is sum of reciprocal ranks")
    func twoRetrievers() {
        let fused = RRF.fuse([[ChunkID("a"), ChunkID("b")], [ChunkID("b"), ChunkID("a")]], k: 60, topK: 2)
        #expect(Set(fused.map(\.0)) == [ChunkID("a"), ChunkID("b")])
        // Max possible = 2/(60+1); each item ranks #1 in one retriever and #2
        // in the other (not #1 in both), so neither hits the theoretical max.
        // Raw = 1/61 + 1/62 ≈ 0.03252; norm = raw / (2/61) ≈ 0.9919, so
        // |fused − 1.0| ≈ 0.0081 — within 1e-2, NOT 1e-3.
        #expect(abs(fused[0].1 - 1.0) < 1e-2)
    }

    @Test("topK bounds the output")
    func topKBound() {
        let fused = RRF.fuse([[ChunkID("a"), ChunkID("b"), ChunkID("c")]], k: 60, topK: 1)
        #expect(fused.count == 1)
    }
}
```

- [ ] **Step 2: Implement**

```swift
package enum RRF {
    package static func fuse(_ rankings: [[ChunkID]], k: Int = 60, topK: Int) -> [(ChunkID, Float)] {
        var raw: [ChunkID: Float] = [:]
        for ranking in rankings {
            for (rank, id) in ranking.enumerated() {
                raw[id, default: 0] += 1.0 / Float(k + rank + 1)
            }
        }
        let theoreticalMax = Float(rankings.count) / Float(k + 1)
        return raw.map { ($0.key, $0.value / theoreticalMax) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.rawValue < $1.0.rawValue }
            .prefix(topK)
            .map { $0 }
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
swift test --filter RRFTests
git add Sources/MemSearch/RRF/ Tests/MemSearchTests/RRFTests.swift
git commit -m "feat(MemSearch): RRF.fuse helper (normalized to [0,1])"
```

---

## Task 12: Scanner (test-after)

**Goal:** Walk directories, return `.md` / `.markdown` URLs in deterministic order. Thin wrapper over `FileManager.enumerator`.

**Files:**

- Create: `Sources/MemSearch/Scanner/Scanner.swift`, `Tests/MemSearchTests/ScannerTests.swift`.

- [ ] **Step 1: Implement**

```swift
import Foundation

public enum Scanner {
    public static func scan(paths: [URL]) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for path in paths {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                if isMarkdown(path) { out.append(path) }
                continue
            }
            let opts: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
            guard let enumerator = fm.enumerator(at: path, includingPropertiesForKeys: nil, options: opts) else { continue }
            for case let url as URL in enumerator where isMarkdown(url) { out.append(url) }
        }
        return out.sorted { $0.path < $1.path }
    }

    private static func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown"].contains(url.pathExtension.lowercased())
    }
}
```

- [ ] **Step 2: Test against a tempdir**

```swift
import Foundation
import Testing
@testable import MemSearch

@Suite("Scanner")
struct ScannerTests {
    @Test("finds .md and .markdown; skips .txt")
    func basics() throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "a".write(to: tmp.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "b".write(to: tmp.appendingPathComponent("b.markdown"), atomically: true, encoding: .utf8)
        try "c".write(to: tmp.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        let out = Scanner.scan(paths: [tmp])
        #expect(out.count == 2)
    }

    private func makeTempDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scan-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
```

- [ ] **Step 3: Commit**

```bash
swift test --filter ScannerTests
git add Sources/MemSearch/Scanner/ Tests/MemSearchTests/ScannerTests.swift
git commit -m "feat(MemSearch): Scanner (FileManager enumerator over .md/.markdown)"
```

---

## Task 13: Error-lifting helper (TDD)

**Goal:** `package` helper that lifts narrow errors into `MemSearchError`. **`Swift.CancellationError` flows through unchanged** (spec line 949).

**Files:**

- Create: `Sources/MemSearch/Engine/ErrorLifting.swift`, `Tests/MemSearchTests/ErrorLiftingTests.swift`.

- [ ] **Step 1: Test**

```swift
import Foundation
import Testing
@testable import MemSearch

@Suite("Error lifting")
struct ErrorLiftingTests {
    @Test("EmbeddingError → .embedding preserves cause")
    func liftsEmbedding() {
        let cause = EmbeddingError.networkFailure(URLError(.notConnectedToInternet))
        guard case let lifted as MemSearchError = MemSearchEngineErrors.lift(cause),
              case .embedding(.networkFailure(let underlying as URLError)) = lifted else {
            Issue.record("wrong shape"); return
        }
        #expect(underlying.code == .notConnectedToInternet)
    }

    @Test("VectorStoreError → .store preserves reason")
    func liftsStore() {
        guard case let lifted as MemSearchError = MemSearchEngineErrors.lift(
            VectorStoreError.schemaIncompatible(reason: "v2")),
              case .store(.schemaIncompatible(let r)) = lifted else { Issue.record("wrong"); return }
        #expect(r == "v2")
    }

    @Test("CancellationError flows through unchanged")
    func cancellation() {
        let lifted = MemSearchEngineErrors.lift(CancellationError())
        #expect(lifted is CancellationError)
    }

    @Test("Unknown error returns unchanged — caller decides how to wrap")
    func unknown() {
        struct X: Error, Sendable {}
        let lifted = MemSearchEngineErrors.lift(X())
        #expect(lifted is X)
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation

package enum MemSearchEngineErrors {
    /// Maps known narrow errors to `MemSearchError`. `Swift.CancellationError`
    /// flows through unchanged. Unknown errors are returned as-is — the catch
    /// site decides whether to wrap further (typically by re-throwing inside
    /// a typed-catch context, or by wrapping in `UnknownIndexError`).
    ///
    /// Uses `some Error` opaque parameter (SE-0352) so call sites with a
    /// concrete typed error don't pay an existential boxing round-trip.
    /// At call sites with `any Error` (e.g. an untyped `catch`), Swift
    /// implicitly opens the existential.
    package static func lift(_ error: some Error) -> any Error {
        if error is CancellationError         { return error }
        if let e = error as? MemSearchError   { return e }
        if let e = error as? EmbeddingError   { return MemSearchError.embedding(e) }
        if let e = error as? VectorStoreError { return MemSearchError.store(e) }
        if let e = error as? LLMError         { return MemSearchError.llm(e) }
        return error
    }
}
```

- [ ] **Step 3: Commit**

```bash
swift test --filter ErrorLiftingTests
git add Sources/MemSearch/Engine/ErrorLifting.swift Tests/MemSearchTests/ErrorLiftingTests.swift
git commit -m "feat(MemSearch): error-lifting helper (preserves cancellation)"
```

---

## Task 14: `MemSearch<V, E>` engine — init + search (TDD)

**Goal:** Engine struct + `search`. `Sendable` unconditionally per spec line 339. `search` embeds the query and delegates to `store.hybridSearch`. Errors lift at the boundary.

**Files:**

- Create: `Sources/MemSearch/Engine/MemSearch.swift`, `Tests/MemSearchTests/EngineSearchTests.swift`.

- [ ] **Step 1: Test**

```swift
import Foundation
import Testing
@testable import MemSearch

@Suite("Engine.search")
struct EngineSearchTests {
    @Test("delegates to store.hybridSearch")
    func delegates() async throws {
        let store = MockVectorStore(dimension: 8)
        let embedder = MockEmbeddingProvider(dimension: 8)
        let mem = MemSearch(paths: [], store: store, embedder: embedder)

        let chunk = Chunk(id: ChunkID("z"), source: URL(fileURLWithPath: "/x.md"),
                          heading: "h", headingLevel: 1, startLine: 1, endLine: 1,
                          content: "x", contentHash: ChunkID.contentHash(for: "x"))
        let canned: [SearchHit] = [SearchHit(chunk: chunk, score: 0.9, denseScore: 0.9, bm25Score: nil)]
        await store.setCannedHits(canned)

        let hits = try await mem.search("hello", topK: 3)
        #expect(hits == canned)
        #expect(embedder.callCount == 1)
    }

    @Test("EmbeddingError lifts to MemSearchError.embedding")
    func liftsEmbedding() async {
        let store = MockVectorStore(dimension: 8)
        let embedder = MockEmbeddingProvider(dimension: 8, injectedFailures: ["q": .authenticationFailed])
        let mem = MemSearch(paths: [], store: store, embedder: embedder)
        await #expect(throws: MemSearchError.self) { _ = try await mem.search("q") }
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation

public struct MemSearch<V: VectorStore, E: EmbeddingProvider>: Sendable {
    public let paths: [URL]
    public let chunkingPolicy: ChunkingPolicy
    package let store: V
    package let embedder: E

    public init(paths: [URL], store: V, embedder: E, chunkingPolicy: ChunkingPolicy = .default) {
        self.paths = paths; self.store = store; self.embedder = embedder; self.chunkingPolicy = chunkingPolicy
    }

    public func search(_ query: String, topK: Int = 10, filter: SourceFilter? = nil) async throws -> [SearchHit] {
        do {
            let qVec = try await embedder.embed([query])[0]
            let hq = HybridQuery(queryText: query, queryEmbedding: qVec, topK: topK, filter: filter, rrfK: 60)
            return try await store.hybridSearch(hq)
        } catch {
            throw MemSearchEngineErrors.lift(error)
        }
    }

    /// Read-only snapshot of engine state for hosts (CLI `info`, SwiftUI
    /// dashboards). Public so consumers in **sibling SwiftPM packages** —
    /// where `package`-scoped `store` and `embedder` aren't visible — can
    /// still introspect basic counts. Errors lift through `MemSearchError`
    /// the same way `search()` does.
    public func summary() async throws -> EngineSummary {
        do {
            return try await store.summary()
        } catch {
            throw MemSearchEngineErrors.lift(error)
        }
    }
}
```

- [ ] **Step 3: Commit**

```bash
swift test --filter EngineSearchTests
git add Sources/MemSearch/Engine/MemSearch.swift Tests/MemSearchTests/EngineSearchTests.swift
git commit -m "feat(MemSearch): engine struct + search"
```

---

## Task 15: `indexStream` + `index` (reduce-invariant TDD)

**Goal:** `indexStream` yields `IndexEvent` per file plus orphaned-source cleanup. `index()` is a `reduce` over `indexStream()` — single source of truth (spec lines 345–349, 365–371). Per-file pipeline: cancel-check → read → chunk → diff against `chunkIDs(forSource:)` → delete stale → embed → upsert → yield.

**Files:**

- Create: `Sources/MemSearch/Engine/MemSearch+Indexing.swift`, `Tests/MemSearchTests/EngineReduceInvariantTests.swift`, `EngineIndexStreamTests.swift`.

- [ ] **Step 1: Reduce-invariant test**

```swift
import Foundation
import Testing
@testable import MemSearch

@Suite("index() reduces over indexStream()")
struct EngineReduceInvariantTests {
    @Test("index() == MemSearch.reduce(indexStream() events) on a single engine")
    func reduceMatch() async throws {
        let tmp = makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        try "# A\nbody A".write(to: tmp.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "# B\nbody B".write(to: tmp.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)

        // First engine: drain indexStream into an event array, then call the
        // exposed `reduce` directly. This is what `index()` does internally.
        let mem1 = MemSearch(
            paths: [tmp],
            store: MockVectorStore(dimension: 8),
            embedder: MockEmbeddingProvider(dimension: 8)
        )
        var events: [IndexEvent] = []
        for try await ev in mem1.indexStream() { events.append(ev) }
        let direct = IndexStats.reduce(events)

        // Second engine, fresh state, same fixture: `index()` aggregates internally.
        // Equivalence proves index() = reduce(indexStream()) under the deterministic
        // mock chunker + mock embedder we use here.
        let mem2 = MemSearch(
            paths: [tmp],
            store: MockVectorStore(dimension: 8),
            embedder: MockEmbeddingProvider(dimension: 8)
        )
        let viaIndex = try await mem2.index()
        #expect(viaIndex.filesScanned == direct.filesScanned)
        #expect(viaIndex.chunksAdded  == direct.chunksAdded)
        #expect(viaIndex.chunksRemoved == direct.chunksRemoved)
        #expect(viaIndex.failedFiles  == direct.failedFiles)
    }

    private func makeTempDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("idx-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation

extension MemSearch {

    public func index(force: Bool = false) async throws -> IndexStats {
        var events: [IndexEvent] = []
        for try await ev in indexStream(force: force) { events.append(ev) }
        return IndexStats.reduce(events)
    }

    public func indexStream(force: Bool = false) -> AsyncThrowingStream<IndexEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    let urls = Scanner.scan(paths: paths)
                    let urlSet = Set(urls)
                    for url in urls {
                        try Task.checkCancellation()
                        do {
                            let event = try await indexOne(url: url, force: force, modelName: embedder.modelName)
                            continuation.yield(event)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch let e as EmbeddingError {
                            continuation.yield(.failed(url, .embedding(e)))
                        } catch let e as VectorStoreError {
                            continuation.yield(.failed(url, .store(e)))
                        } catch let e as IndexFileError {
                            continuation.yield(.failed(url, e))
                        } catch {
                            // Unknown error: render via `LocalizedError` /
                            // `NSError.localizedDescription` so the carrier
                            // surfaces something readable to SwiftUI alerts
                            // rather than raw `"\(error)"` (which leaks Swift
                            // type names like `"FileSystemRequiresPermission()"`).
                            let message = (error as? LocalizedError)?.errorDescription
                                ?? (error as NSError).localizedDescription
                            continuation.yield(.failed(url, .scan(UnknownIndexError(message: message))))
                        }
                    }
                    let known = try await store.indexedSources()
                    for orphan in known.subtracting(urlSet) {
                        try Task.checkCancellation()
                        let count = try await store.delete(source: orphan)
                        continuation.yield(.removed(orphan, chunkCount: count))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: MemSearchEngineErrors.lift(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func indexFile(_ url: URL) async throws -> Int {
        do {
            let event = try await indexOne(url: url, force: false, modelName: embedder.modelName)
            if case .indexed(_, let a, _) = event { return a }
            return 0
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as EmbeddingError {
            throw MemSearchError.embedding(e)
        } catch let e as VectorStoreError {
            throw MemSearchError.store(e)
        } catch {
            // Same Sendable-boundary reasoning as indexStream's catch-all.
            // Unwrap through `LocalizedError` so the SwiftUI alert sees a
            // readable string, not a raw `"\(error)"` type-name leak.
            let message = (error as? LocalizedError)?.errorDescription
                ?? (error as NSError).localizedDescription
            throw MemSearchError.scan(url, UnknownIndexError(message: message))
        }
    }

    private func indexOne(url: URL, force: Bool, modelName: String) async throws -> IndexEvent {
        let text = try String(contentsOf: url, encoding: .utf8)
        let chunks = Chunker.chunk(text: text, source: url, policy: chunkingPolicy, embedderModelName: modelName)
        let known = try await store.chunkIDs(forSource: url)
        let newIDs = Set(chunks.map(\.id))
        let stale = known.subtracting(newIDs)
        let removedCount = stale.isEmpty ? 0 : try await store.delete(ids: Array(stale))

        let toUpsert = force ? chunks : chunks.filter { !known.contains($0.id) }
        if toUpsert.isEmpty {
            return .indexed(url, added: 0, removed: removedCount)
        }
        let embeddings = try await embedder.embed(toUpsert.map(\.content))
        let records = zip(toUpsert, embeddings).map { StoredChunk(chunk: $0, embedding: $1) }
        let added = try await store.upsert(records)
        return .indexed(url, added: added, removed: removedCount)
    }
}

/// Sendable carrier for unknown errors caught at the engine boundary so that
/// `IndexFileError.scan(any Error & Sendable)` and
/// `MemSearchError.scan(URL, any Error & Sendable)` always carry *something*
/// — never silently drop a file. `description` is what `LocalizedError`
/// renders into SwiftUI alerts. `internal` because it's a transient catch-
/// block carrier — hosts read it through `LocalizedError.errorDescription`,
/// not by pattern-match.
struct UnknownIndexError: Error, Sendable, CustomStringConvertible, LocalizedError {
    let message: String
    init(message: String) { self.message = message }
    var description: String { message }
    var errorDescription: String? { message }
}

extension IndexStats {
    /// Pure reducer over `IndexEvent`. `MemSearch.index()` calls this on its
    /// own `indexStream()` events; tests invoke it directly to verify the
    /// "index() == reduce(indexStream())" invariant. Non-generic — one
    /// canonical instantiation, regardless of `MemSearch<V, E>` specialization
    /// (loop-2 reviewer fix: was `MemSearch.reduce` static, which forced a
    /// per-specialization copy in the binary).
    package static func reduce(_ events: [IndexEvent]) -> IndexStats {
        var added = 0, removed = 0, scanned = 0, failed: [URL] = []
        for ev in events {
            switch ev {
            case .indexed(_, let a, let r): scanned += 1; added += a; removed += r
            case .removed(_, let n):        removed += n
            case .failed(let url, _):       failed.append(url)
            }
        }
        return IndexStats(filesScanned: scanned, chunksAdded: added, chunksRemoved: removed, failedFiles: failed)
    }
}
```

- [ ] **Step 3: indexStream basic test**

```swift
@Suite("indexStream events")
struct EngineIndexStreamTests {
    @Test("emits .indexed per file then completes") func basic() async throws { /* fixture w/ 3 files; assert 3 .indexed events */ }
    @Test("emits .removed for orphans on second pass") func orphans() async throws { /* index then remove a file then index again; assert .removed */ }
}
```

- [ ] **Step 4: Commit**

```bash
swift test --filter EngineReduceInvariantTests --filter EngineIndexStreamTests
git add Sources/MemSearch/Engine/MemSearch+Indexing.swift Tests/MemSearchTests/EngineReduceInvariantTests.swift Tests/MemSearchTests/EngineIndexStreamTests.swift
git commit -m "feat(MemSearch): index + indexStream + indexFile (reduce-invariant)"
```

---

## Task 16: `indexStream` cancellation propagation (TDD)

**Goal:** Cancellation of the consumer surfaces as `CancellationError`, never as `MemSearchError`. Spec line 949. Uses `MockEmbeddingProvider.latencyPerBatch` for the documented suspension point.

**Files:**

- Create: `Tests/MemSearchTests/EngineCancellationTests.swift`.

- [ ] **Step 1: Test**

```swift
import Foundation
import Testing
@testable import MemSearch

@Suite("Engine cancellation")
struct EngineCancellationTests {
    @Test("indexStream cancellation surfaces as CancellationError")
    func cancels() async throws {
        let tmp = makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        for i in 0..<10 {
            try "# H\nbody \(i)".write(to: tmp.appendingPathComponent("\(i).md"), atomically: true, encoding: .utf8)
        }
        let embedder = MockEmbeddingProvider(dimension: 8, latencyPerBatch: .milliseconds(200))
        let mem = MemSearch(paths: [tmp], store: MockVectorStore(dimension: 8), embedder: embedder)

        let task = Task {
            for try await _ in mem.indexStream() {}
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    private func makeTempDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cancel-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
```

- [ ] **Step 2: Run + commit**

```bash
swift test --filter EngineCancellationTests
git add Tests/MemSearchTests/EngineCancellationTests.swift
git commit -m "test(MemSearch): indexStream cancellation surfaces as CancellationError"
```

---

## Task 17: Sendable compile gate + Engine round-trip

**Goal:** Two tests:
- **Sendable compile gate:** assert `MemSearch<MockVectorStore, MockEmbeddingProvider>` is `Sendable` without escapes. The compile *is* the assertion.
- **Round-trip:** `index()` → `search()` end-to-end against a tempdir + mocks.

**Files:**

- Create: `Tests/MemSearchTests/SendableCompileGateTests.swift`, `EngineRoundTripTests.swift`.

- [ ] **Step 1: Sendable gate**

```swift
import Foundation
import Testing
@testable import MemSearch

private func _gate(_ mem: sending MemSearch<MockVectorStore, MockEmbeddingProvider>) async {
    await Task.detached { _ = mem }.value
}

@Suite("Sendable compile gate")
struct SendableCompileGateTests {
    @Test("MemSearch<MockVectorStore, MockEmbeddingProvider>: Sendable")
    func compiles() async {
        let mem = MemSearch(paths: [], store: MockVectorStore(dimension: 8), embedder: MockEmbeddingProvider(dimension: 8))
        await _gate(mem)
    }
}
```

- [ ] **Step 2: Round-trip**

```swift
@Suite("Engine round-trip")
struct EngineRoundTripTests {
    @Test("index then search returns hits")
    func roundTrip() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "# H\nbody".write(to: tmp.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)

        let mem = MemSearch(paths: [tmp], store: MockVectorStore(dimension: 8), embedder: MockEmbeddingProvider(dimension: 8))
        let stats = try await mem.index()
        #expect(stats.filesScanned == 1)
        #expect(stats.chunksAdded > 0)
        let hits = try await mem.search("body", topK: 5)
        #expect(!hits.isEmpty)
    }
}
```

- [ ] **Step 3: Commit**

```bash
swift test --filter SendableCompileGateTests --filter EngineRoundTripTests
git add Tests/MemSearchTests/SendableCompileGateTests.swift Tests/MemSearchTests/EngineRoundTripTests.swift
git commit -m "test(MemSearch): Sendable compile gate + engine round-trip"
```

---

## Task 18: Stub `summarize` / `appendSummary` / `watch` with `.unimplemented`

**Goal:** Declare the v1 surface; throw `MemSearchError.unimplemented(...)`. Hosts and the SwiftUI integration appendix can compile against the full surface today.

**Files:**

- Create: `Sources/MemSearch/Engine/MemSearch+Stubs.swift`, `Tests/MemSearchTests/EngineStubsTests.swift`.

- [ ] **Step 1: Implement**

```swift
import Foundation

extension MemSearch {
    public func summarize<S: LLMSummarizer>(
        using summarizer: S,
        source: URL? = nil,
        promptTemplate: String? = nil,
        now: Date = Date()
    ) async throws -> CompactedSummary {
        throw MemSearchError.unimplemented("summarize: implemented in Phase 6")
    }

    public func appendSummary(_ summary: CompactedSummary, to outputDirectory: URL? = nil) async throws -> URL {
        throw MemSearchError.unimplemented("appendSummary: implemented in Phase 6")
    }

    public func watch(
        debounce: Duration = .milliseconds(250),
        bufferingPolicy: AsyncStream<IndexEvent>.Continuation.BufferingPolicy = .bufferingNewest(1024)
    ) throws -> AsyncStream<IndexEvent> {
        throw MemSearchError.unimplemented("watch: implemented in Phase 4")
    }
}
```

- [ ] **Step 2: Test**

```swift
@Suite("Engine stubs")
struct EngineStubsTests {
    @Test("watch throws .unimplemented")
    func watchUnimplemented() {
        let mem = MemSearch(paths: [], store: MockVectorStore(dimension: 8), embedder: MockEmbeddingProvider(dimension: 8))
        #expect(throws: MemSearchError.self) { _ = try mem.watch() }
    }
    @Test("summarize throws .unimplemented")
    func summarizeUnimplemented() async {
        let mem = MemSearch(paths: [], store: MockVectorStore(dimension: 8), embedder: MockEmbeddingProvider(dimension: 8))
        await #expect(throws: MemSearchError.self) { _ = try await mem.summarize(using: MockSummarizer()) }
    }
}
```

- [ ] **Step 3: Commit**

```bash
swift test --filter EngineStubsTests
git add Sources/MemSearch/Engine/MemSearch+Stubs.swift Tests/MemSearchTests/EngineStubsTests.swift
git commit -m "feat(MemSearch): stub summarize/appendSummary/watch with .unimplemented"
```

---

## Task 19: SQLite schema + migrations (TDD)

**Goal:** `SQLiteVectorStore` init + close, and the GRDB migration registrar that creates `chunks_meta`, `chunks_vec` (vec0 virtual), `chunks_fts` (FTS5 virtual), plus FTS5 sync triggers. Every connection registers `sqlite-vec` via `Configuration.prepareDatabase` (Spike 0a pattern; spec lines 419–456).

**Files:**

- Create: `Sources/MemSearchSQLite/SQLiteVectorStore.swift`, `SQLiteSchema.swift`.
- Create: `Tests/MemSearchSQLiteTests/SchemaMigrationTests.swift`.
- Delete: `Sources/MemSearchSQLite/_LinkSmoke.swift` (replaced by real symbol use).

- [ ] **Step 1: `SQLiteVectorStore` init + close**

```swift
import Foundation
import GRDB
import SQLite3
import SQLiteVec
import MemSearch

public final class SQLiteVectorStore: VectorStore, Sendable {
    public nonisolated let dimension: Int
    package let pool: DatabasePool

    public init(url: URL, dimension: Int) async throws {
        var config = Configuration()
        config.prepareDatabase { db in
            var errMsg: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_vec_init(db.sqliteConnection, &errMsg, nil)
            guard rc == SQLITE_OK else {
                let msg = errMsg.flatMap { String(cString: $0) } ?? "sqlite3_vec_init failed (rc=\(rc))"
                if errMsg != nil { sqlite3_free(errMsg) }
                throw VectorStoreError.connectionFailed(
                    NSError(domain: "sqlite-vec", code: Int(rc),
                            userInfo: [NSLocalizedDescriptionKey: msg])
                )
            }
        }
        do {
            self.pool = try DatabasePool(path: url.path, configuration: config)
        } catch {
            throw VectorStoreError.connectionFailed(error)
        }
        self.dimension = dimension
        try await SQLiteSchema.migrate(pool: pool, dimension: dimension)
    }

    public func close() async { /* GRDB closes on dealloc */ }
}
```

- [ ] **Step 2: Schema migrator**

```swift
import Foundation
import GRDB
import MemSearch

enum SQLiteSchema {
    static func migrate(pool: DatabasePool, dimension: Int) async throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE chunks_meta(
                    chunk_id TEXT PRIMARY KEY,
                    source TEXT NOT NULL,
                    heading TEXT NOT NULL,
                    heading_level INTEGER NOT NULL,
                    start_line INTEGER NOT NULL,
                    end_line INTEGER NOT NULL,
                    content TEXT NOT NULL,
                    content_hash TEXT NOT NULL
                );
            """)
            try db.execute(sql: "CREATE INDEX idx_chunks_meta_source ON chunks_meta(source);")
            try db.execute(sql: "CREATE VIRTUAL TABLE chunks_vec USING vec0(embedding float[\(dimension)]);")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE chunks_fts USING fts5(
                    content, content='chunks_meta', content_rowid='rowid', tokenize='porter unicode61'
                );
            """)
            try db.execute(sql: "CREATE TRIGGER chunks_meta_ai AFTER INSERT ON chunks_meta BEGIN INSERT INTO chunks_fts(rowid,content) VALUES (new.rowid,new.content); END;")
            try db.execute(sql: "CREATE TRIGGER chunks_meta_ad AFTER DELETE ON chunks_meta BEGIN INSERT INTO chunks_fts(chunks_fts,rowid,content) VALUES ('delete',old.rowid,old.content); END;")
            try db.execute(sql: "CREATE TRIGGER chunks_meta_au AFTER UPDATE ON chunks_meta BEGIN INSERT INTO chunks_fts(chunks_fts,rowid,content) VALUES ('delete',old.rowid,old.content); INSERT INTO chunks_fts(rowid,content) VALUES (new.rowid,new.content); END;")
        }
        do { try await pool.write { db in try migrator.migrate(db) } }
        catch { throw VectorStoreError.connectionFailed(error) }
    }
}
```

- [ ] **Step 3: Test schema**

```swift
import Foundation
import Testing
import GRDB
@testable import MemSearchSQLite

@Suite("SQLite schema migration")
struct SchemaMigrationTests {
    @Test("init creates the expected virtual tables")
    func tables() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("schema-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try await SQLiteVectorStore(url: url, dimension: 8)
        let names: [String] = try await store.pool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type IN ('table','view') ORDER BY name")
        }
        #expect(names.contains("chunks_meta"))
        #expect(names.contains("chunks_vec"))
        #expect(names.contains("chunks_fts"))
    }
}
```

- [ ] **Step 4: Cleanup + commit**

```bash
rm Sources/MemSearchSQLite/_LinkSmoke.swift
swift test --filter SchemaMigrationTests
git add Sources/MemSearchSQLite/SQLiteVectorStore.swift Sources/MemSearchSQLite/SQLiteSchema.swift Tests/MemSearchSQLiteTests/SchemaMigrationTests.swift
git rm Sources/MemSearchSQLite/_LinkSmoke.swift
git commit -m "feat(MemSearchSQLite): schema + GRDB migrations + sqlite-vec init"
```

---

## Task 20: SQLiteVectorStore CRUD (TDD)

**Goal:** `upsert` / `delete(ids:)` / `delete(source:)` / `indexedSources` / `chunkIDs(forSource:)`. All writes are single-tx. `dimensionMismatch` thrown on bad embedding.

**Files:**

- Create: `Sources/MemSearchSQLite/SQLiteRowCoding.swift`.
- Modify: `Sources/MemSearchSQLite/SQLiteVectorStore.swift` (CRUD methods).
- Create: `Tests/MemSearchSQLiteTests/CRUDTests.swift`.

- [ ] **Step 1: Row coding**

```swift
import Foundation
import GRDB
import MemSearch

extension Chunk {
    static func make(fromMetaRow row: Row) -> Chunk {
        Chunk(
            id: ChunkID(row["chunk_id"] as String),
            source: URL(fileURLWithPath: row["source"] as String),
            heading: row["heading"] as String,
            headingLevel: row["heading_level"] as Int,
            startLine: row["start_line"] as Int,
            endLine: row["end_line"] as Int,
            content: row["content"] as String,
            contentHash: row["content_hash"] as String
        )
    }
}

func embeddingBlob(_ values: [Float]) -> Data {
    values.withUnsafeBufferPointer { Data(buffer: $0) }
}
```

- [ ] **Step 2: CRUD methods**

```swift
extension SQLiteVectorStore {

    public func upsert(_ records: [StoredChunk]) async throws -> Int {
        guard !records.isEmpty else { return 0 }
        for r in records where r.embedding.dimension != dimension {
            throw VectorStoreError.dimensionMismatch(expected: dimension, got: r.embedding.dimension)
        }
        do {
            return try await pool.write { db in
                for r in records {
                    try db.execute(sql: """
                        INSERT OR REPLACE INTO chunks_meta(chunk_id,source,heading,heading_level,start_line,end_line,content,content_hash)
                        VALUES (?,?,?,?,?,?,?,?)
                    """, arguments: [
                        r.chunk.id.rawValue, r.chunk.source.path, r.chunk.heading, r.chunk.headingLevel,
                        r.chunk.startLine, r.chunk.endLine, r.chunk.content, r.chunk.contentHash,
                    ])
                    let rowid: Int64 = try Int64.fetchOne(db,
                        sql: "SELECT rowid FROM chunks_meta WHERE chunk_id = ?",
                        arguments: [r.chunk.id.rawValue])!
                    try db.execute(sql: "INSERT OR REPLACE INTO chunks_vec(rowid,embedding) VALUES (?,?)",
                                   arguments: [rowid, embeddingBlob(r.embedding.values)])
                }
                return records.count
            }
        } catch let e as VectorStoreError { throw e }
        catch { throw VectorStoreError.backendError(error) }
    }

    public func delete(ids: [ChunkID]) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        do {
            return try await pool.write { db in
                var n = 0
                for id in ids {
                    if let r: Int64 = try Int64.fetchOne(db, sql: "SELECT rowid FROM chunks_meta WHERE chunk_id = ?", arguments: [id.rawValue]) {
                        try db.execute(sql: "DELETE FROM chunks_vec WHERE rowid = ?", arguments: [r])
                        try db.execute(sql: "DELETE FROM chunks_meta WHERE chunk_id = ?", arguments: [id.rawValue])
                        n += 1
                    }
                }
                return n
            }
        } catch { throw VectorStoreError.backendError(error) }
    }

    public func delete(source: URL) async throws -> Int {
        do {
            return try await pool.write { db in
                let rowids: [Int64] = try Int64.fetchAll(db,
                    sql: "SELECT rowid FROM chunks_meta WHERE source = ?", arguments: [source.path])
                for r in rowids {
                    try db.execute(sql: "DELETE FROM chunks_vec WHERE rowid = ?", arguments: [r])
                }
                try db.execute(sql: "DELETE FROM chunks_meta WHERE source = ?", arguments: [source.path])
                return rowids.count
            }
        } catch { throw VectorStoreError.backendError(error) }
    }

    public func indexedSources() async throws -> Set<URL> {
        do {
            let paths: [String] = try await pool.read { db in
                try String.fetchAll(db, sql: "SELECT DISTINCT source FROM chunks_meta")
            }
            return Set(paths.map { URL(fileURLWithPath: $0) })
        } catch { throw VectorStoreError.backendError(error) }
    }

    public func chunkIDs(forSource source: URL) async throws -> Set<ChunkID> {
        do {
            let ids: [String] = try await pool.read { db in
                try String.fetchAll(db, sql: "SELECT chunk_id FROM chunks_meta WHERE source = ?", arguments: [source.path])
            }
            return Set(ids.map(ChunkID.init))
        } catch { throw VectorStoreError.backendError(error) }
    }
}
```

- [ ] **Step 3: CRUD tests**

```swift
@Suite("SQLite CRUD")
struct CRUDTests {
    @Test func upsertAndQuery() async throws { /* upsert one chunk, indexedSources == [src], chunkIDs(forSource:) == {id} */ }
    @Test func deleteByIDs() async throws { /* upsert two, delete one, indexedSources still has src; chunkIDs has 1 */ }
    @Test func deleteBySource() async throws { /* upsert, delete(source:), indexedSources empty */ }
    @Test func dimensionMismatchThrows() async throws {
        let store = try await SQLiteVectorStore(url: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).db"), dimension: 8)
        let chunk = Chunk(id: ChunkID("x"), source: URL(fileURLWithPath: "/x.md"),
                          heading: "", headingLevel: 0, startLine: 1, endLine: 1, content: "x", contentHash: "x")
        let emb = try Embedding(values: [0.1,0.2,0.3], expectedDimension: 3)
        await #expect(throws: VectorStoreError.self) { _ = try await store.upsert([StoredChunk(chunk: chunk, embedding: emb)]) }
    }
}
```

- [ ] **Step 4: Commit**

```bash
swift test --filter CRUDTests
git add Sources/MemSearchSQLite/ Tests/MemSearchSQLiteTests/CRUDTests.swift
git commit -m "feat(MemSearchSQLite): CRUD"
```

---

## Task 21: SQLiteVectorStore.hybridSearch single-tx (TDD)

**Goal:** vec0 KNN + FTS5 BM25 inside one `pool.read { db in ... }` (no `await` inside). RRF fuses ID rankings. Spec lines 437–456.

**Files:**

- Create: `Sources/MemSearchSQLite/SQLiteHybridSearch.swift`.
- Create: `Tests/MemSearchSQLiteTests/HybridSearchTests.swift`.

- [ ] **Step 1: Implement**

```swift
import Foundation
import GRDB
import MemSearch

extension SQLiteVectorStore {
    public func hybridSearch(_ q: HybridQuery) async throws -> [SearchHit] {
        guard q.queryEmbedding.dimension == dimension else {
            throw VectorStoreError.dimensionMismatch(expected: dimension, got: q.queryEmbedding.dimension)
        }
        do {
            return try await pool.read { db in
                let candidates = max(q.topK * 5, 50)
                let qBlob = embeddingBlob(q.queryEmbedding.values)

                let denseRows = try Row.fetchAll(db, sql: """
                    SELECT chunks_meta.chunk_id AS cid, chunks_vec.distance AS dist
                    FROM chunks_vec JOIN chunks_meta ON chunks_meta.rowid = chunks_vec.rowid
                    WHERE chunks_vec.embedding MATCH ?
                    ORDER BY chunks_vec.distance LIMIT ?
                """, arguments: [qBlob, candidates])
                let denseRanking: [(ChunkID, Float)] = denseRows.map { (ChunkID($0["cid"] as String), Float($0["dist"] as Double)) }

                let ftsRows = try Row.fetchAll(db, sql: """
                    SELECT chunks_meta.chunk_id AS cid, bm25(chunks_fts) AS score
                    FROM chunks_fts JOIN chunks_meta ON chunks_meta.rowid = chunks_fts.rowid
                    WHERE chunks_fts MATCH ?
                    ORDER BY score LIMIT ?
                """, arguments: [q.queryText, candidates])
                let ftsRanking: [(ChunkID, Float)] = ftsRows.map { (ChunkID($0["cid"] as String), Float($0["score"] as Double)) }

                let fused = RRF.fuse([denseRanking.map(\.0), ftsRanking.map(\.0)], k: q.rrfK, topK: q.topK)
                let denseScores = Dictionary(uniqueKeysWithValues: denseRanking)
                let bm25Scores  = Dictionary(uniqueKeysWithValues: ftsRanking)
                let ids = fused.map(\.0.rawValue)
                guard !ids.isEmpty else { return [] }
                let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
                let metaRows = try Row.fetchAll(db,
                    sql: "SELECT * FROM chunks_meta WHERE chunk_id IN (\(placeholders))",
                    arguments: StatementArguments(ids))
                let chunksByID = Dictionary(uniqueKeysWithValues: metaRows.map {
                    (ChunkID($0["chunk_id"] as String), Chunk.make(fromMetaRow: $0))
                })

                return fused.compactMap { id, fusedScore in
                    guard let chunk = chunksByID[id] else { return nil }
                    return SearchHit(chunk: chunk, score: fusedScore, denseScore: denseScores[id], bm25Score: bm25Scores[id])
                }
            }
        } catch let e as VectorStoreError { throw e }
        catch { throw VectorStoreError.backendError(error) }
    }
}
```

**Single-tx note:** the entire fusion lives inside one `pool.read` closure. If a future refactor splits these into two reads, snapshot consistency breaks. Spec line 437.

- [ ] **Step 2: Test**

```swift
@Suite("hybridSearch")
struct HybridSearchTests {
    @Test("returns hits with dense + bm25 scores populated")
    func hits() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try await SQLiteVectorStore(url: url, dimension: 8)
        for i in 0..<3 {
            let chunk = Chunk(id: ChunkID(String(format: "id%015d", i)), source: URL(fileURLWithPath: "/x\(i).md"),
                              heading: "h", headingLevel: 1, startLine: 1, endLine: 1,
                              content: "hello world \(i)", contentHash: ChunkID.contentHash(for: "hello world \(i)"))
            var v = [Float](repeating: 0, count: 8); v[i] = 1
            _ = try await store.upsert([StoredChunk(chunk: chunk, embedding: try Embedding(values: v, expectedDimension: 8))])
        }
        var qVec = [Float](repeating: 0, count: 8); qVec[0] = 1
        let hits = try await store.hybridSearch(HybridQuery(
            queryText: "hello world 0",
            queryEmbedding: try Embedding(values: qVec, expectedDimension: 8),
            topK: 3, filter: nil, rrfK: 60))
        #expect(!hits.isEmpty)
        #expect(hits[0].denseScore != nil)
        #expect(hits[0].bm25Score != nil)
        #expect(hits[0].score >= 0 && hits[0].score <= 1)
    }
}
```

- [ ] **Step 3: Commit**

```bash
swift test --filter HybridSearchTests
git add Sources/MemSearchSQLite/SQLiteHybridSearch.swift Tests/MemSearchSQLiteTests/HybridSearchTests.swift
git commit -m "feat(MemSearchSQLite): hybridSearch (single-tx vec0+FTS5+RRF)"
```

---

## Task 22: SQLiteVectorStore.scan + summary (TDD)

**Goal:** `scan(filter:)` streams every chunk matching the optional source-prefix filter. `summary()` returns snapshot-consistent `(sourceCount, chunkCount)` inside one `pool.read`. Both validate the `@Sendable` capture inside the GRDB-wrapping closure. Spec lines 226–232 (scan); `summary()` is a loop-2-review spec patch (the protocol method was added to avoid an N+1 racy aggregation at the engine level).

**Files:**

- Modify: `Sources/MemSearchSQLite/SQLiteVectorStore.swift` (add `scan` + `summary`).
- Create: `Tests/MemSearchSQLiteTests/ScanSmokeTests.swift`, `SummarySnapshotTests.swift`.

- [ ] **Step 1: Implement**

```swift
extension SQLiteVectorStore {
    public nonisolated func scan(filter: SourceFilter?) -> AsyncThrowingStream<Chunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [pool] in
                do {
                    // Observe cancellation before issuing the read — GRDB's
                    // `pool.read` await only surfaces cancellation when it
                    // returns, which on a slow query is too late.
                    try Task.checkCancellation()
                    let rows = try await pool.read { db -> [Row] in
                        if let f = filter {
                            return try Row.fetchAll(db,
                                sql: "SELECT * FROM chunks_meta WHERE source LIKE ? ORDER BY chunk_id",
                                arguments: [f.prefix.path + "%"])
                        }
                        return try Row.fetchAll(db, sql: "SELECT * FROM chunks_meta ORDER BY chunk_id")
                    }
                    for row in rows {
                        try Task.checkCancellation()
                        continuation.yield(Chunk.make(fromMetaRow: row))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Snapshot-consistent counts inside one `pool.read` — both `COUNT`
    /// expressions execute against the same SQLite snapshot, so concurrent
    /// `upsert`/`delete` calls cannot produce torn `(sources, chunks)` pairs.
    public func summary() async throws -> EngineSummary {
        do {
            return try await pool.read { db in
                let row = try Row.fetchOne(db, sql: """
                    SELECT COUNT(DISTINCT source) AS sources, COUNT(*) AS chunks
                    FROM chunks_meta
                """)!
                return EngineSummary(
                    sourceCount: row["sources"] as Int,
                    chunkCount:  row["chunks"]  as Int
                )
            }
        } catch let e as VectorStoreError { throw e }
        catch { throw VectorStoreError.backendError(error) }
    }
}
```

- [ ] **Step 2: Test**

```swift
@Suite("scan stream")
struct ScanSmokeTests {
    @Test("drains every chunk")
    func drains() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try await SQLiteVectorStore(url: url, dimension: 8)
        for i in 0..<5 {
            let c = Chunk(id: ChunkID("id\(i)"), source: URL(fileURLWithPath: "/x.md"),
                          heading: "h", headingLevel: 1, startLine: 1, endLine: 1,
                          content: "x\(i)", contentHash: ChunkID.contentHash(for: "x\(i)"))
            _ = try await store.upsert([StoredChunk(chunk: c, embedding: try Embedding(values: Array(repeating: 0, count: 8), expectedDimension: 8))])
        }
        var seen = 0
        for try await _ in store.scan(filter: nil) { seen += 1 }
        #expect(seen == 5)
    }
}

@Suite("summary snapshot")
struct SummarySnapshotTests {
    @Test("counts (sources, chunks) inside one read transaction")
    func counts() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try await SQLiteVectorStore(url: url, dimension: 8)
        // 3 sources × 2 chunks each = 6 chunks total.
        for src in ["/a.md", "/b.md", "/c.md"] {
            for line in [1, 10] {
                let c = Chunk(
                    id: ChunkID("\(src)-\(line)"),
                    source: URL(fileURLWithPath: src),
                    heading: "h", headingLevel: 1,
                    startLine: line, endLine: line + 1,
                    content: "body \(line)",
                    contentHash: ChunkID.contentHash(for: "body \(line)")
                )
                _ = try await store.upsert([StoredChunk(
                    chunk: c,
                    embedding: try Embedding(values: Array(repeating: 0, count: 8), expectedDimension: 8)
                )])
            }
        }
        let snap = try await store.summary()
        #expect(snap.sourceCount == 3)
        #expect(snap.chunkCount == 6)
    }
}
```

- [ ] **Step 3: Commit**

```bash
swift test --filter ScanSmokeTests --filter SummarySnapshotTests
git add Sources/MemSearchSQLite/SQLiteVectorStore.swift \
        Tests/MemSearchSQLiteTests/ScanSmokeTests.swift \
        Tests/MemSearchSQLiteTests/SummarySnapshotTests.swift
git commit -m "feat(MemSearchSQLite): scan stream + summary snapshot (single-tx)"
```

---

## Task 23: OpenAIEmbedder + wire types (TDD)

**Goal:** `OpenAIEmbedder` is a `final class : Sendable` over `URLSession.shared`. Posts to `{baseURL}/embeddings` with the OpenAI wire format. Returns `[Embedding]` such that `result[i]` corresponds to `texts[i]`.

**Files:**

- Create: `Sources/MemSearchEmbeddersHTTP/OpenAIEmbedder.swift`, `OpenAIWire.swift`, `HTTPCancellation.swift`.
- Create: `Tests/MemSearchEmbeddersHTTPTests/OpenAIWireTests.swift`.

- [ ] **Step 1: Wire DTOs**

`Sources/MemSearchEmbeddersHTTP/OpenAIWire.swift`:

```swift
import Foundation

struct OpenAIEmbeddingRequest: Codable, Sendable {
    let input: [String]
    let model: String
}

struct OpenAIEmbeddingResponse: Codable, Sendable {
    struct Datum: Codable, Sendable { let embedding: [Float]; let index: Int }
    let data: [Datum]
}
```

- [ ] **Step 2: HTTP cancellation translation helper**

`Sources/MemSearchEmbeddersHTTP/HTTPCancellation.swift`:

```swift
import Foundation
import MemSearch

/// Translates a caught `URLError` from a `URLSession.data(for:)` await.
///
/// Cooperative cancellation path: if the surrounding `Task` is cancelled,
/// `try Task.checkCancellation()` throws `CancellationError` — which is what
/// hosts pattern-match. Spec line 949 mandates that `Swift.CancellationError`
/// flows through unchanged.
///
/// Non-task-driven URL cancel (rare; e.g. URLSessionConfiguration
/// `timeoutIntervalForRequest`): returns the URLError as
/// `EmbeddingError.networkFailure(URLError)` so hosts can retry.
func translateURLError(_ urlError: URLError) throws -> Never {
    if urlError.code == .cancelled {
        try Task.checkCancellation()   // throws CancellationError if Task cancelled
        throw EmbeddingError.networkFailure(urlError)
    }
    throw EmbeddingError.networkFailure(urlError)
}
```

- [ ] **Step 3: `OpenAIEmbedder`**

`Sources/MemSearchEmbeddersHTTP/OpenAIEmbedder.swift`:

```swift
import Foundation
import MemSearch

public final class OpenAIEmbedder: EmbeddingProvider, Sendable {
    public nonisolated let modelName: String
    public nonisolated let dimension: Int

    let apiKey: String
    let baseURL: URL
    let session: URLSession

    public init(
        apiKey: String,
        model: String = "text-embedding-3-small",
        dimension: Int = 1536,
        baseURL: URL = URL(string: "https://api.openai.com/v1")!,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.modelName = model
        self.dimension = dimension
        self.baseURL = baseURL
        self.session = session
    }

    public func embed(_ texts: [String]) async throws -> [Embedding] {
        guard !texts.isEmpty else { return [] }

        let url = baseURL.appendingPathComponent("embeddings")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(OpenAIEmbeddingRequest(input: texts, model: modelName))

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch let urlError as URLError {
            try translateURLError(urlError)   // throws CancellationError or EmbeddingError.networkFailure
        }

        guard let http = response as? HTTPURLResponse else {
            throw EmbeddingError.networkFailure(URLError(.badServerResponse))
        }
        switch http.statusCode {
        case 200..<300: break
        case 401:
            throw EmbeddingError.authenticationFailed
        case 429:
            let retry: Duration? = http.value(forHTTPHeaderField: "Retry-After")
                .flatMap(Double.init).map(Duration.seconds)
            throw EmbeddingError.rateLimited(retryAfter: retry)
        default:
            throw EmbeddingError.networkFailure(URLError(.badServerResponse))
        }

        let decoded: OpenAIEmbeddingResponse
        do {
            decoded = try JSONDecoder().decode(OpenAIEmbeddingResponse.self, from: data)
        } catch {
            throw EmbeddingError.decodingFailed(error)
        }

        let sorted = decoded.data.sorted { $0.index < $1.index }
        guard sorted.count == texts.count else {
            throw EmbeddingError.decodingFailed(URLError(.badServerResponse))
        }
        return try sorted.map { try Embedding(values: $0.embedding, expectedDimension: dimension) }
    }
}
```

- [ ] **Step 4: Wire-format tests**

`Tests/MemSearchEmbeddersHTTPTests/OpenAIWireTests.swift`:

```swift
import Foundation
import Testing
@testable import MemSearchEmbeddersHTTP

@Suite("OpenAI wire format")
struct OpenAIWireTests {

    @Test("request encodes input + model")
    func encode() throws {
        let req = OpenAIEmbeddingRequest(input: ["hi", "there"], model: "text-embedding-3-small")
        let json = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(req)) as! [String: Any]
        #expect(json["model"] as? String == "text-embedding-3-small")
        #expect((json["input"] as? [String])?.count == 2)
    }

    @Test("response decodes data array preserving index order")
    func decode() throws {
        let body = #"""
        {"data":[{"index":1,"embedding":[0.3,0.4]},{"index":0,"embedding":[0.1,0.2]}]}
        """#
        let resp = try JSONDecoder().decode(OpenAIEmbeddingResponse.self, from: Data(body.utf8))
        #expect(resp.data.count == 2)
        let sorted = resp.data.sorted { $0.index < $1.index }
        #expect(sorted[0].embedding == [0.1, 0.2])
        #expect(sorted[1].embedding == [0.3, 0.4])
    }
}
```

- [ ] **Step 5: Run + commit**

```bash
swift test --filter OpenAIWireTests
git add Sources/MemSearchEmbeddersHTTP/OpenAIEmbedder.swift \
        Sources/MemSearchEmbeddersHTTP/OpenAIWire.swift \
        Sources/MemSearchEmbeddersHTTP/HTTPCancellation.swift \
        Tests/MemSearchEmbeddersHTTPTests/OpenAIWireTests.swift
git commit -m "feat(MemSearchEmbeddersHTTP): OpenAIEmbedder (final class : Sendable)"
```

---

## Task 24: OpenAIEmbedder cancellation pattern (TDD)

**Goal:** Phase 0 patch 4: `URLError(.cancelled)` is translated via `try Task.checkCancellation()` so cancellation surfaces as `CancellationError` on the cooperative path. Spec line 377; phasing-doc patch 4. Test using a custom `URLProtocol` stub.

**Files:**

- Create: `Tests/MemSearchEmbeddersHTTPTests/OpenAICancellationTests.swift`.

- [ ] **Step 1: Test**

```swift
import Foundation
import Testing
@testable import MemSearchEmbeddersHTTP
import MemSearch

/// `URLProtocol` subclasses are NSObject family and own internal mutable
/// state; the URL Loading System manages their lifecycle. Test-only mock
/// — `@unchecked Sendable` is the established Apple-platform pattern here
/// (cf. Apple's URLSession docs example). The Task 9 ban on escapes was
/// scoped to Sources/; tests have a documented exception.
final class CancelStubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }
    override func stopLoading() {}
}

@Suite("OpenAI cancellation translation")
struct OpenAICancellationTests {

    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [CancelStubProtocol.self]
        return URLSession(configuration: cfg)
    }

    @Test("URLError(.cancelled) on a cancelled Task surfaces as CancellationError")
    func cancelledTask() async throws {
        let session = makeSession()
        let embedder = OpenAIEmbedder(apiKey: "k", session: session)

        let outer = Task {
            try await embedder.embed(["hi"])
        }
        outer.cancel()

        await #expect(throws: CancellationError.self) { _ = try await outer.value }
    }

    @Test("URLError(.cancelled) on a NON-cancelled task surfaces as EmbeddingError.networkFailure")
    func nonTaskCancellation() async throws {
        let session = makeSession()
        let embedder = OpenAIEmbedder(apiKey: "k", session: session)

        // Run on a non-cancelled Task — `try Task.checkCancellation()` does NOT throw,
        // so the embedder re-throws as networkFailure.
        await #expect(throws: EmbeddingError.self) {
            _ = try await embedder.embed(["hi"])
        }
    }
}
```

- [ ] **Step 2: Run + commit**

```bash
swift test --filter OpenAICancellationTests
git add Tests/MemSearchEmbeddersHTTPTests/OpenAICancellationTests.swift
git commit -m "test(MemSearchEmbeddersHTTP): URLError(.cancelled) → CancellationError"
```

---

## Task 25: CLI scaffolding — `AsyncParsableCommand` + `BackendDispatch`

**Goal:** Wire up the three subcommands behind `memsearch`. MVP dispatch: 1 case (sqlite × openai). Errors propagate via `swift-argument-parser`'s standard error handling. Programmatic init is also exercised via the CLI (no config file required when `--config` is absent and env vars provide everything).

**Scaling note (loop-2 review):** `BackendDispatch.run` is hand-written in Phase 1 because there's only one case. Phase 2 doubles to 2 cases (Core ML), Phase 3 quadruples to 4 (SwiftData × {openai, coreml}), and Phase 5 reaches 8 cases. The original spec defers macro generation to Phase 6 (16 cases) — bring it forward to **Phase 4** instead. By the end of Phase 3 the switch is already 4 cases of near-identical bodies; a `@CLISubcommand` (or codegen) lands cleanly there before Phase 5/6 add another 12. Phase 1 ships hand-written; this note is a pointer for the implementer when Phase 3 begins.

**Files:**

- Modify: `cli/Sources/memsearch/main.swift`.
- Create: `cli/Sources/memsearch/Subcommands/{IndexCommand,SearchCommand,InfoCommand}.swift`.
- Create: `cli/Sources/memsearch/Dispatch/BackendDispatch.swift`.
- Create: `cli/Sources/memsearch/Config/ResolvedConfig.swift`.

- [ ] **Step 1: `ResolvedConfig` value type**

`cli/Sources/memsearch/Config/ResolvedConfig.swift`:

```swift
import Foundation
import MemSearch

public struct ResolvedConfig: Sendable {
    public enum Backend: String, Codable, Sendable { case sqlite }
    public enum Provider: String, Codable, Sendable { case openai }

    public struct Store: Sendable {
        public let backend: Backend
        public let path: URL
        public init(backend: Backend, path: URL) { self.backend = backend; self.path = path }
    }
    public struct Embedder: Sendable {
        public let provider: Provider
        public let model: String
        public let dimension: Int
        public let apiKey: String?
        public let baseURL: URL?
        public init(provider: Provider, model: String, dimension: Int, apiKey: String?, baseURL: URL?) {
            self.provider = provider; self.model = model; self.dimension = dimension
            self.apiKey = apiKey; self.baseURL = baseURL
        }
    }

    public let paths: [URL]
    public let store: Store
    public let embedder: Embedder
    public let chunkingPolicy: ChunkingPolicy

    public init(paths: [URL], store: Store, embedder: Embedder, chunkingPolicy: ChunkingPolicy) {
        self.paths = paths; self.store = store; self.embedder = embedder; self.chunkingPolicy = chunkingPolicy
    }
}
```

- [ ] **Step 2: `BackendDispatch`**

`cli/Sources/memsearch/Dispatch/BackendDispatch.swift`:

```swift
import Foundation
import MemSearch
import MemSearchSQLite
import MemSearchEmbeddersHTTP

enum BackendDispatch {

    /// Phase 1 supports exactly 1 dispatch case: sqlite × openai.
    /// Phase 2+ extends to 4 cases (Core ML), Phase 3 to 8 (SwiftData × {openai, coreml}),
    /// Phase 5 to 8 (4 embedders × 2 stores), Phase 6 to 16 (× 2 summarizers).
    /// At Phase 6 the cartesian product warrants macro generation.
    static func run<R: Sendable>(
        _ cfg: ResolvedConfig,
        _ body: @Sendable (MemSearch<SQLiteVectorStore, OpenAIEmbedder>) async throws -> R
    ) async throws -> R {
        guard cfg.store.backend == .sqlite, cfg.embedder.provider == .openai else {
            throw MemSearchError.configurationInvalid("Phase 1 supports only sqlite + openai")
        }
        let store = try await SQLiteVectorStore(url: cfg.store.path, dimension: cfg.embedder.dimension)
        let embedder = OpenAIEmbedder(
            apiKey: cfg.embedder.apiKey ?? "",
            model: cfg.embedder.model,
            dimension: cfg.embedder.dimension,
            baseURL: cfg.embedder.baseURL ?? URL(string: "https://api.openai.com/v1")!
        )
        let mem = MemSearch(paths: cfg.paths, store: store, embedder: embedder, chunkingPolicy: cfg.chunkingPolicy)
        return try await body(mem)
    }
}
```

- [ ] **Step 3: `main.swift`**

Replace the stub `cli/Sources/memsearch/main.swift`:

```swift
import ArgumentParser

@main
struct Memsearch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "memsearch",
        abstract: "Semantic memory search for Markdown notes",
        subcommands: [IndexCommand.self, SearchCommand.self, InfoCommand.self]
    )
}

struct CommonOptions: ParsableArguments {
    @Option(help: "Path to a config file (JSON; .json)") var config: String?
    @Option(help: "Override paths (comma-separated)") var paths: String?
}
```

- [ ] **Step 4: Build (subcommands stub for compile)**

Add temporary placeholder subcommand files so `main.swift` compiles. Tasks 26–28 fill them in. Stubs:

```swift
// cli/Sources/memsearch/Subcommands/IndexCommand.swift
import ArgumentParser
struct IndexCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "index")
    func run() async throws { fatalError("populated in Task 26") }
}
```

(Same shape for `SearchCommand` and `InfoCommand`.)

- [ ] **Step 5: Commit**

```bash
cd cli && swift build && cd ..
git add cli/Sources/memsearch/
git commit -m "feat(memsearch CLI): scaffolding + BackendDispatch + ResolvedConfig"
```

---

## Task 26: CLI `index` subcommand

**Goal:** `memsearch index [--paths ...] [--config ...] [--force]`. Streams progress lines per file. Exits 0 on success, non-zero on failure.

**Files:**

- Replace: `cli/Sources/memsearch/Subcommands/IndexCommand.swift`.

- [ ] **Step 1: Implement**

```swift
import ArgumentParser
import Foundation
import MemSearch

struct IndexCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "index", abstract: "Index Markdown files")
    @OptionGroup var common: CommonOptions
    @Flag(name: .long, help: "Re-index even when chunks are unchanged")
    var force: Bool = false

    func run() async throws {
        let cfg = try ResolvedConfig.load(common: common)
        try await BackendDispatch.run(cfg) { mem in
            for try await event in mem.indexStream(force: force) {
                let line: String
                switch event {
                case .indexed(let url, let added, let removed):
                    line = "indexed \(url.lastPathComponent) (+\(added) -\(removed))\n"
                case .removed(let url, let n):
                    line = "removed \(url.lastPathComponent) (-\(n))\n"
                case .failed(let url, let err):
                    let desc = (err as? LocalizedError)?.errorDescription ?? "\(err)"
                    FileHandle.standardError.write(Data("failed \(url.lastPathComponent): \(desc)\n".utf8))
                    continue
                }
                FileHandle.standardOutput.write(Data(line.utf8))
            }
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
cd cli && swift build && cd ..
git add cli/Sources/memsearch/Subcommands/IndexCommand.swift
git commit -m "feat(memsearch CLI): index subcommand"
```

---

## Task 27: CLI `search` subcommand (with `--json`)

**Goal:** `memsearch search "query" [-k 5] [--json]`. JSON keys stable per spec lines 858–874.

**Files:**

- Replace: `cli/Sources/memsearch/Subcommands/SearchCommand.swift`.
- Create: `cli/Tests/MemSearchCLITests/JSONOutputTests.swift`.

- [ ] **Step 1: Implement**

```swift
import ArgumentParser
import Foundation
import MemSearch

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "search", abstract: "Hybrid search over the index")
    @OptionGroup var common: CommonOptions
    @Argument var query: String
    @Option(name: .shortAndLong) var k: Int = 10
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let cfg = try ResolvedConfig.load(common: common)
        try await BackendDispatch.run(cfg) { mem in
            let hits = try await mem.search(query, topK: k)
            if json {
                let envelope = SearchOutput(hits: hits.map(SearchOutput.Hit.init))
                let data = try JSONEncoder.outputEncoder.encode(envelope)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                for hit in hits {
                    let line = String(
                        format: "%.3f  %@:%d-%d  %@\n",
                        hit.score,
                        hit.chunk.source.lastPathComponent,
                        hit.chunk.startLine,
                        hit.chunk.endLine,
                        hit.chunk.heading
                    )
                    FileHandle.standardOutput.write(Data(line.utf8))
                }
            }
        }
    }
}

struct SearchOutput: Codable, Sendable {
    let hits: [Hit]
    struct Hit: Codable, Sendable {
        let chunkID: String
        let source: String
        let heading: String
        let score: Float
        let denseScore: Float?
        let bm25Score: Float?
        let startLine: Int
        let endLine: Int
        let content: String

        init(_ h: SearchHit) {
            self.chunkID = h.chunk.id.rawValue
            self.source = h.chunk.source.path
            self.heading = h.chunk.heading
            self.score = h.score
            self.denseScore = h.denseScore
            self.bm25Score = h.bm25Score
            self.startLine = h.chunk.startLine
            self.endLine = h.chunk.endLine
            self.content = h.chunk.content
        }

        enum CodingKeys: String, CodingKey {
            case chunkID = "chunk_id"
            case source, heading, score
            case denseScore = "dense_score"
            case bm25Score = "bm25_score"
            case startLine = "start_line"
            case endLine = "end_line"
            case content
        }
    }
}

extension JSONEncoder {
    static let outputEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}
```

- [ ] **Step 2: JSON shape test**

`cli/Tests/MemSearchCLITests/JSONOutputTests.swift`:

```swift
import Foundation
import Testing
@testable import memsearch
import MemSearch

@Suite("Search JSON output")
struct JSONOutputTests {
    @Test("schema keys stable across versions")
    func keys() throws {
        let chunk = Chunk(
            id: ChunkID("abc"),
            source: URL(fileURLWithPath: "/x.md"),
            heading: "h", headingLevel: 1, startLine: 1, endLine: 5,
            content: "c", contentHash: "ch"
        )
        let hit = SearchHit(chunk: chunk, score: 0.9, denseScore: 0.8, bm25Score: 0.1)
        let data = try JSONEncoder.outputEncoder.encode(SearchOutput(hits: [SearchOutput.Hit(hit)]))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hits = json["hits"] as! [[String: Any]]
        #expect(hits[0]["chunk_id"] as? String == "abc")
        #expect(hits[0]["dense_score"] != nil)
        #expect(hits[0]["bm25_score"] != nil)
        #expect(hits[0]["start_line"] as? Int == 1)
        #expect(hits[0]["end_line"] as? Int == 5)
    }
}
```

- [ ] **Step 3: Commit**

```bash
cd cli && swift build && swift test --filter JSONOutputTests && cd ..
git add cli/Sources/memsearch/Subcommands/SearchCommand.swift cli/Tests/MemSearchCLITests/JSONOutputTests.swift
git commit -m "feat(memsearch CLI): search subcommand (--json stable schema)"
```

---

## Task 28: CLI `info` subcommand

**Goal:** `memsearch info` prints store path, backend, embedder, source count, total chunk count.

**Files:**

- Replace: `cli/Sources/memsearch/Subcommands/InfoCommand.swift`.

- [ ] **Step 1: Implement**

```swift
import ArgumentParser
import Foundation
import MemSearch

struct InfoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "info", abstract: "Show store stats")
    @OptionGroup var common: CommonOptions

    func run() async throws {
        let cfg = try ResolvedConfig.load(common: common)
        try await BackendDispatch.run(cfg) { mem in
            // `mem.summary()` is the public engine snapshot — `mem.store` is
            // `package`-scoped and not visible from this sibling SPM package.
            let snap = try await mem.summary()
            let summary = """
                Store path: \(cfg.store.path.path)
                Backend:    \(cfg.store.backend.rawValue)
                Embedder:   \(cfg.embedder.provider.rawValue) (\(cfg.embedder.model), dim \(cfg.embedder.dimension))
                Sources:    \(snap.sourceCount)
                Chunks:     \(snap.chunkCount)

                """
            FileHandle.standardOutput.write(Data(summary.utf8))
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
cd cli && swift build && cd ..
git add cli/Sources/memsearch/Subcommands/InfoCommand.swift
git commit -m "feat(memsearch CLI): info subcommand"
```

---

## Task 29: JSON config loader (test-after) + EnvResolver + programmatic init

**Goal:** Layered config: defaults → `~/.config/memsearch/config.json` → `./.memsearch.json` → CLI flags. The schema is a `Codable` value type loaded with `JSONDecoder`; the loader dispatches on file extension so YAML/TOML add-ons later only require new cases (no other call-site changes). Env-var resolution: `${VAR}` (throws on unset), `${VAR:-default}`, `$$` literal escape. Spec lines 894–921, modulo the format swap.

**Files:**

- Create: `cli/Sources/memsearch/Config/{ConfigLoader,EnvResolver}.swift`.
- Modify: `cli/Sources/memsearch/Config/ResolvedConfig.swift` (add `MemSearchConfigFile` schema + `load(common:)`).
- Create: `cli/Tests/MemSearchCLITests/{ConfigLoaderTests,EnvResolverTests}.swift`.

- [ ] **Step 1: `EnvResolver`**

`cli/Sources/memsearch/Config/EnvResolver.swift`:

```swift
import Foundation
import MemSearch

public enum EnvResolver {
    /// Resolves `${VAR}` and `${VAR:-default}` placeholders in the input string.
    /// Literal `$` is escaped as `$$`. Throws `MemSearchError.configurationInvalid`
    /// if a `${VAR}` (no default) names an unset environment variable.
    public static func resolve(
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
                if parts.count == 2, parts[1].hasPrefix("-") {
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
```

- [ ] **Step 2: Config schema (`Codable` value type)**

Append to `cli/Sources/memsearch/Config/ResolvedConfig.swift`:

```swift
/// On-disk shape of a memsearch config file. JSON in v1; the same `Codable`
/// struct round-trips through future YAML/TOML decoders without changing
/// any call site — only `ConfigLoader.load(at:)` adds a new dispatch case.
struct MemSearchConfigFile: Codable, Sendable {
    var paths: [String]?
    var store: Store?
    var embedder: Embedder?
    var chunking: Chunking?

    struct Store: Codable, Sendable {
        var backend: ResolvedConfig.Backend?
        var path: String?
    }

    struct Embedder: Codable, Sendable {
        var provider: ResolvedConfig.Provider?
        var model: String?
        var dimension: Int?
        var apiKey: String?
        var baseURL: String?

        enum CodingKeys: String, CodingKey {
            case provider, model, dimension
            case apiKey  = "api_key"
            case baseURL = "base_url"
        }
    }

    struct Chunking: Codable, Sendable {
        var maxChunkSize: Int?
        var overlapLines: Int?

        enum CodingKeys: String, CodingKey {
            case maxChunkSize = "max_chunk_size"
            case overlapLines = "overlap_lines"
        }
    }
}
```

JSON keys are snake_case (industry convention for config files); Swift properties stay camelCase via explicit `CodingKeys`. We *don't* use `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase` because that strategy mishandles all-uppercase tokens (`baseURL` would round-trip through `base_u_r_l`).

`backend` and `provider` are typed enums (`ResolvedConfig.Backend`, `ResolvedConfig.Provider`) rather than `String?` — typo'd values fail at JSON-decode time with file:line, not later inside `ResolvedConfig.load`.

- [ ] **Step 3: `ConfigLoader` — format dispatch**

`cli/Sources/memsearch/Config/ConfigLoader.swift`:

```swift
import Foundation
import MemSearch

/// Loads a `MemSearchConfigFile` from disk. v1 supports JSON only; YAML / TOML
/// add-on cases are reserved by the file-extension dispatch below.
enum ConfigLoader {
    static func load(at url: URL) throws -> MemSearchConfigFile? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        switch url.pathExtension.lowercased() {
        case "json":
            return try JSONDecoder().decode(MemSearchConfigFile.self, from: data)
        case "yml", "yaml", "toml":
            throw MemSearchError.configurationInvalid(
                "config format '\(url.pathExtension)' not supported in v1; only .json is supported. " +
                "(YAML/TOML loaders plug in at this dispatch in a later phase.)"
            )
        default:
            throw MemSearchError.configurationInvalid(
                "unknown config file extension: '\(url.pathExtension)'. v1 supports .json only."
            )
        }
    }

    /// Default config locations searched when `--config` is not given:
    /// 1. `~/.config/memsearch/config.json`
    /// 2. `./.memsearch.json`
    static func defaultPaths() -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let cwd  = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return [
            home.appendingPathComponent(".config/memsearch/config.json"),
            cwd.appendingPathComponent(".memsearch.json"),
        ]
    }
}
```

- [ ] **Step 4: `ResolvedConfig.load(common:)`**

Append to `cli/Sources/memsearch/Config/ResolvedConfig.swift`:

```swift
extension ResolvedConfig {
    static func load(common: CommonOptions) throws -> ResolvedConfig {
        var merged = MemSearchConfigFile()
        let configFiles: [URL] = {
            if let p = common.config { return [URL(fileURLWithPath: p)] }
            return ConfigLoader.defaultPaths()
        }()
        for url in configFiles {
            if let layer = try ConfigLoader.load(at: url) {
                merged = merge(into: merged, layer: layer)
            }
        }

        // CLI flag override: --paths wins over the merged config.
        let pathStrings = common.paths?.split(separator: ",").map { String($0) }
            ?? merged.paths
            ?? [(NSHomeDirectory() as NSString).appendingPathComponent("Documents/notes")]
        let paths = pathStrings.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

        let backend = merged.store?.backend ?? .sqlite
        let storePathRaw = merged.store?.path
            ?? "~/Library/Application Support/MemSearch/memory.db"
        let storePath = URL(fileURLWithPath: (storePathRaw as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(
            at: storePath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let provider  = merged.embedder?.provider ?? .openai
        let model     = merged.embedder?.model ?? "text-embedding-3-small"
        let dimension = merged.embedder?.dimension ?? 1536
        let apiKey    = try merged.embedder?.apiKey.map { try EnvResolver.resolve($0) }
        let baseURL   = (merged.embedder?.baseURL).flatMap { URL(string: $0) }

        let chunking = ChunkingPolicy(
            maxChunkSize: merged.chunking?.maxChunkSize ?? 1500,
            overlapLines: merged.chunking?.overlapLines ?? 2
        )

        return ResolvedConfig(
            paths: paths,
            store: .init(backend: backend, path: storePath),
            embedder: .init(provider: provider, model: model, dimension: dimension, apiKey: apiKey, baseURL: baseURL),
            chunkingPolicy: chunking
        )
    }
}

private func merge(into base: MemSearchConfigFile, layer: MemSearchConfigFile) -> MemSearchConfigFile {
    var out = base
    if let p = layer.paths { out.paths = p }
    if let s = layer.store {
        var m = out.store ?? .init()
        if let v = s.backend { m.backend = v }
        if let v = s.path    { m.path = v }
        out.store = m
    }
    if let e = layer.embedder {
        var m = out.embedder ?? .init()
        if let v = e.provider  { m.provider = v }
        if let v = e.model     { m.model = v }
        if let v = e.dimension { m.dimension = v }
        if let v = e.apiKey    { m.apiKey = v }
        if let v = e.baseURL   { m.baseURL = v }
        out.embedder = m
    }
    if let c = layer.chunking {
        var m = out.chunking ?? .init()
        if let v = c.maxChunkSize { m.maxChunkSize = v }
        if let v = c.overlapLines { m.overlapLines = v }
        out.chunking = m
    }
    return out
}
```

- [ ] **Step 5: Tests**

`cli/Tests/MemSearchCLITests/EnvResolverTests.swift`:

```swift
import Testing
@testable import memsearch
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
}
```

`cli/Tests/MemSearchCLITests/ConfigLoaderTests.swift`:

```swift
import Foundation
import Testing
@testable import memsearch
import MemSearch

@Suite("ConfigLoader + ResolvedConfig.load")
struct ConfigLoaderTests {

    @Test("defaults apply when no config file is present")
    func defaultsApplyWhenNoConfig() throws {
        let cfg = try ResolvedConfig.load(common: CommonOptions(config: "/nonexistent.json", paths: nil))
        #expect(cfg.embedder.provider == .openai)
        #expect(cfg.chunkingPolicy.maxChunkSize == 1500)
        #expect(cfg.chunkingPolicy.overlapLines == 2)
    }

    @Test("JSON overrides defaults; CLI --paths wins over JSON")
    func jsonOverridesDefaults() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).json")
        let body = #"""
        {
          "paths": ["/tmp/notes"],
          "embedder": {
            "model": "text-embedding-3-large",
            "dimension": 3072
          }
        }
        """#
        try body.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let cfg = try ResolvedConfig.load(common: CommonOptions(config: tmp.path, paths: nil))
        #expect(cfg.embedder.dimension == 3072)
        #expect(cfg.paths == [URL(fileURLWithPath: "/tmp/notes")])

        let cliOverride = try ResolvedConfig.load(common: CommonOptions(config: tmp.path, paths: "/cli/path"))
        #expect(cliOverride.paths == [URL(fileURLWithPath: "/cli/path")])
    }

    @Test("api_key / base_url JSON keys decode into apiKey / baseURL Swift names")
    func snakeCaseKeys() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).json")
        let body = #"""
        {"embedder": {"api_key": "sk-test", "base_url": "https://example.invalid/v1"}}
        """#
        try body.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cfg = try ResolvedConfig.load(common: CommonOptions(config: tmp.path, paths: nil))
        #expect(cfg.embedder.apiKey == "sk-test")
        #expect(cfg.embedder.baseURL?.absoluteString == "https://example.invalid/v1")
    }

    @Test("unsupported format throws MemSearchError.configurationInvalid")
    func unsupportedFormat() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).yaml")
        try "paths:\n  - /tmp\n".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(throws: MemSearchError.self) {
            _ = try ResolvedConfig.load(common: CommonOptions(config: tmp.path, paths: nil))
        }
    }
}
```

- [ ] **Step 6: Programmatic-init smoke note**

Append to `docs/superpowers/phases/phase-1-notes.md`:

```markdown
## Programmatic init verified

`MemSearch(paths:store:embedder:)` constructs without any config-file loading.
The iOS-style construction path (host calls `try await SQLiteVectorStore(url:dimension:)`,
constructs `OpenAIEmbedder(apiKey:model:dimension:)`, and passes both to
`MemSearch.init`) compiles and runs. Coverage proxied by the engine round-trip
test (Task 17) which uses the same construction shape.
```

- [ ] **Step 7: Commit**

```bash
cd cli && swift test && cd ..
git add cli/Sources/memsearch/Config/ \
        cli/Tests/MemSearchCLITests/EnvResolverTests.swift \
        cli/Tests/MemSearchCLITests/ConfigLoaderTests.swift \
        docs/superpowers/phases/phase-1-notes.md
git commit -m "feat(memsearch CLI): JSON ConfigLoader + EnvResolver + ResolvedConfig.load"
```

---

## Task 30: Per-phase ritual — iOS Simulator compile gate + SwiftUI host-snippet check

**Goal:** Run the canonical compile gate against every iOS-required library product. **Loop-1 review add:** also compile the design-spec SwiftUI integration appendix verbatim against an iOS host target so its `@Observable @MainActor` view-model pattern is mechanically validated, not just visually inspected.

**Files:**

- Modify: `docs/superpowers/phases/phase-1-notes.md` (record the run).
- Create: `Tests/MemSearchHostCompileTests/AppendixHostSnippet.swift` (SwiftUI compile-only gate).
- Modify: `Package.swift` (add the host-compile test target).

- [ ] **Step 1: Run the gate against every iOS-required library**

```bash
xcodebuild build -scheme MemSearch \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath /tmp/derived 2>&1 | tail -5
xcodebuild build -scheme MemSearchSQLite \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath /tmp/derived 2>&1 | tail -5
xcodebuild build -scheme MemSearchEmbeddersHTTP \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath /tmp/derived 2>&1 | tail -5
```

Expected: each prints `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Add the SwiftUI host-snippet compile gate**

Append a test target to `Package.swift`:

```swift
.testTarget(
    name: "MemSearchHostCompileTests",
    dependencies: ["MemSearch", "MemSearchSQLite", "MemSearchEmbeddersHTTP"],
    swiftSettings: phase1Settings
),
```

Create `Tests/MemSearchHostCompileTests/AppendixHostSnippet.swift`:

```swift
#if canImport(SwiftUI)
import SwiftUI
import MemSearch
import MemSearchSQLite
import MemSearchEmbeddersHTTP

// This file is **modeled on** the design spec's SwiftUI integration appendix
// (`docs/superpowers/specs/2026-05-20-swift-rewrite-design.md`, lines ~1108–1175).
// It does NOT run — the goal is compile-time validation that the library API
// keeps the host pattern compilable. If this file fails to build, either the
// public engine signature drifted away from the appendix (fix the engine), or
// the appendix is genuinely out of date (patch the spec). The gate also
// exercises `summary()` and `watch()` so any drift in those public surfaces
// fails this gate before it reaches a real host.

typealias AppMem = MemSearch<SQLiteVectorStore, OpenAIEmbedder>

@Observable @MainActor
final class _AppendixHostMemModel {
    let mem: AppMem
    var indexState: IndexState = .idle
    var lastResults: [SearchHit] = []
    var lastSummary: EngineSummary?

    enum IndexState {
        case idle
        case indexing(added: Int, removed: Int)
        case completed(IndexStats)
        case failed(any Error)
    }

    init(mem: AppMem) { self.mem = mem }

    func search(_ q: String) async {
        do { lastResults = try await mem.search(q) }
        catch is CancellationError {}
        catch {}
    }

    func refreshSummary() async {
        lastSummary = try? await mem.summary()
    }

    func startIndex() async {
        indexState = .indexing(added: 0, removed: 0)
        do {
            var added = 0, removed = 0, scanned = 0
            for try await event in mem.indexStream() {
                switch event {
                case .indexed(_, let a, let r):  scanned += 1; added += a; removed += r
                case .removed(_, let n):         removed += n
                case .failed:                    break
                }
                indexState = .indexing(added: added, removed: removed)
            }
            indexState = .completed(IndexStats(filesScanned: scanned, chunksAdded: added, chunksRemoved: removed, failedFiles: []))
        } catch is CancellationError {
            indexState = .idle
        } catch {
            indexState = .failed(error)
        }
    }

    /// Compile-time gate against `MemSearch.watch()`'s signature. The Phase 1
    /// stub throws `.unimplemented`; calling this from a host crashes at
    /// runtime, but the *signature* drift detection is the value here. Phase 4
    /// implements `watch()` for real and this becomes a working subscription.
    func subscribeWatcher() {
        do {
            let stream = try mem.watch()
            Task { for await _ in stream {} }
        } catch {
            // Phase 1 stubs throw .unimplemented; no-op for the gate.
        }
    }
}
#endif
```

Run the iOS compile gate against this test target:

```bash
xcodebuild build -scheme MemSearchHostCompileTests \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath /tmp/derived 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`. Failure indicates the public engine signature drifted away from the appendix — fix one or the other.

- [ ] **Step 3: Record the run**

Append to `docs/superpowers/phases/phase-1-notes.md`:

```markdown
## iOS Simulator compile gate (Phase 1 run)

| Product                           | Result |
| --------------------------------- | ------ |
| `MemSearch`                       | PASS   |
| `MemSearchSQLite`                 | PASS   |
| `MemSearchEmbeddersHTTP`          | PASS   |
| `MemSearchHostCompileTests`       | PASS   |

Date: <fill in>

The host-snippet gate reproduces the design spec's SwiftUI integration
appendix verbatim; if any future task changes a `public` engine method
signature, this gate fails before the design spec drifts.
```

- [ ] **Step 4: Commit**

```bash
git add Package.swift Tests/MemSearchHostCompileTests/ docs/superpowers/phases/phase-1-notes.md
git commit -m "build: iOS Simulator compile-gate + SwiftUI appendix host-snippet check"
```

---

## Task 31: Success criteria verification

**Goal:** Run all seven success criteria from the phasing doc against the built artifacts. Record each.

- [ ] **Criterion 1: `swift test` green**

```bash
swift test
cd cli && swift test && cd ..
```

Expected: every `@Suite` reports zero failures across both packages.

- [ ] **Criterion 2: `swift run memsearch index` succeeds**

```bash
cd cli
export OPENAI_API_KEY=<your key>
swift run memsearch index --paths ../tests/fixtures/python-baseline/corpus
```

Expected: each file reports `indexed <name> (+N -0)`. Final state has > 0 chunks.

- [ ] **Criterion 3: `swift run memsearch search` returns top-K with sane scores**

```bash
swift run memsearch search "How does the chunker split markdown by headings?" -k 5
swift run memsearch search "How does the chunker split markdown by headings?" -k 5 --json | jq .
```

Expected: 5 lines with scores in `[0, 1]`; JSON parses with stable keys.

- [ ] **Criterion 4: `swift run memsearch info` reports stats**

```bash
swift run memsearch info
```

Expected: prints store path, backend, embedder model + dimension, source count, chunk count.

- [ ] **Criterion 5: Idempotency**

Re-run `index` without `--force`:

```bash
swift run memsearch index --paths ../tests/fixtures/python-baseline/corpus
```

Expected: every file reports `indexed <name> (+0 -0)`. No new chunks; no removals.

- [ ] **Criterion 6: Cross-check ≥60% top-3 overlap with Python top-5**

```bash
cat > /tmp/cross_check.py <<'PY'
import json, subprocess, pathlib

queries = json.loads(pathlib.Path("../tests/fixtures/python-baseline/queries.json").read_text())
python = json.loads(pathlib.Path("../tests/fixtures/python-baseline/python-top5.json").read_text())
python_by_q = {row["query"]: [h["chunk_id"] for h in row["top"]] for row in python["results"]}

ok = 0; total = 0
for q in queries["queries"]:
    proc = subprocess.run(
        ["swift", "run", "memsearch", "search", q, "-k", "3", "--json"],
        capture_output=True, text=True, check=True
    )
    swift_top3 = [h["chunk_id"] for h in json.loads(proc.stdout)["hits"]]
    py_top5 = python_by_q[q]
    overlap = len(set(swift_top3) & set(py_top5))
    if overlap >= 1: ok += 1
    total += 1
    print(f"[{overlap}/3] {q}")
print(f"Pass rate: {ok}/{total} = {ok/total*100:.0f}%")
PY
python3 /tmp/cross_check.py
cd ..
```

Expected: ≥60% (≥5/8 with 8 queries).

If below threshold: investigate. Likely culprits, ranked: chunker drift (golden test passed but real corpus exposes an edge case the fixture didn't), `ChunkID` format mismatch with Python, RRF parameter divergence, BM25 tokenization difference. Do not "fix" by lowering the threshold — diagnose the divergence.

- [ ] **Criterion 7: Cancellation surfaces as `CancellationError`**

Already covered by `swift test --filter EngineCancellationTests` and `OpenAICancellationTests` from Criterion 1. Spot-check Ctrl+C behavior on a manual `memsearch index` run against a large corpus — should exit cleanly with no traceback.

- [ ] **Step 8: Record verification in notes**

Append to `docs/superpowers/phases/phase-1-notes.md`:

```markdown
## Success criteria — Phase 1 verification

| # | Criterion                                            | Result      |
|---|------------------------------------------------------|-------------|
| 1 | `swift test` green                                   | PASS        |
| 2 | `memsearch index` runs                               | PASS        |
| 3 | `memsearch search` returns top-K                     | PASS        |
| 4 | `memsearch info` reports stats                       | PASS        |
| 5 | Idempotency on re-index                              | PASS        |
| 6 | ≥60% top-3 overlap with Python top-5                 | PASS (X/8)  |
| 7 | Cancellation surfaces as `CancellationError`         | PASS        |

Date: <fill>
```

- [ ] **Step 9: Commit**

```bash
git add docs/superpowers/phases/phase-1-notes.md
git commit -m "test: Phase 1 success criteria verified"
```

---

## Task 32: Phase 1 wrap — `phase-1-notes.md`

**Goal:** Finalize the notes file. Record surprises, spec deltas, and items deferred to later phases. Mark Phase 1 complete.

- [ ] **Step 1: Fill in remaining sections**

Edit `docs/superpowers/phases/phase-1-notes.md` to flesh out:

```markdown
## Surprises

(record anything that didn't match expectations: golden-test diff iterations,
sqlite-vec compile warnings, Swift Testing quirks, GRDB Swift 6 sendability,
`OSAllocatedUnfairLock` semantics, etc.)

## Spec deltas applied

(record commits with `docs: spec patch — Phase 1 …` if any. None expected
unless a Phase 1 implementation issue invalidates a spec assumption.)

## Items deferred to later phases

- (anything noticed but explicitly not implemented this phase)
- LIKE-glob hardening for `SQLiteVectorStore.scan` filter (Task 22 v2 note).
- Cross-encoder reranker, BM25 in SwiftData, token streaming (per phasing doc
  "Deferred to v2").

## Phase 2 entry checklist

- [ ] Pin a concrete Core ML embedding model identifier (BGE-M3 vs MiniLM-L6
  vs custom). Spike 0b deferred this; Phase 2 closes it.
- [ ] Confirm `Application Support/MemSearch/Models/` works with
  `isExcludedFromBackupKey` on macOS sandbox.
- [ ] swift-transformers iOS-support evidence for the Phase 7 matrix entry
  ("required" for `MemSearchEmbeddersCoreML`).

## Phase 1 status

**COMPLETE.** All seven success criteria green. Library + CLI dogfoodable
against a real notes folder using SQLite + OpenAI.
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/phases/phase-1-notes.md
git commit -m "docs: phase 1 wrap — notes finalized"
```

---

## Self-review notes

**Spec coverage** — every Phase 1 deliverable from the phasing doc has a task:

- All public types (Models/, Errors/) → Tasks 5–7.
- Three protocols → Task 8.
- `MemSearch<V, E>` engine + `index` / `indexStream` / `indexFile` / `search` → Tasks 14–15.
- Chunker (Python parity, golden-anchored) → Task 10.
- `RRF.fuse` → Task 11.
- Scanner → Task 12.
- Configuration value types → CLI Task 25 (`ResolvedConfig`); `ChunkingPolicy` lives in `MemSearch` (Task 6).
- Mocks (content-keyed + latency) → Task 9.
- Error-lifting helper → Task 13.
- `SQLiteVectorStore` (final class : Sendable + DatabasePool + sqlite-vec via prepareDatabase + FTS5 + single-tx hybrid + scan stream) → Tasks 19–22.
- `OpenAIEmbedder` (URLSession.shared + `URLError(.cancelled) → CancellationError` translation) → Tasks 23–24.
- CLI (argument-parser, index/search/info, JSON output, JSON config loader, programmatic init) → Tasks 25–29.
- TDD ordering chunker → RRF → ChunkID → error-lifting → HTTP cancellation → engine reduce-invariant → engine cancellation → actor-boundary Sendable → SQLite schema/CRUD → hybridSearch single-tx → scan smoke is preserved across Tasks 5, 10, 11, 13, 15, 16, 17, 19, 20, 21, 22, 24.
- Per-phase rituals (`swift test`, `swift build`, iOS Simulator compile gate, `phase-N-notes.md`) → Tasks 30–32.
- Phase 1 entry checklist (Python fixture, sqlite-vec decision, Package.swift platforms) → Task 1.

**Loop-1 review fixes + user pivots baked in:**

- **JSON config replaces TOMLDecoder** (user pivot). `cli/Package.swift` drops the external dep entirely; `MemSearchConfigFile` is a plain `Codable` struct loaded with `JSONDecoder` through a format-dispatched `ConfigLoader.load(at:)`. YAML / TOML loaders plug in at the same dispatch in a later phase without touching `ResolvedConfig` (Task 4 + Task 29).
- **`MockEmbeddingProvider` deterministic seed** (loop-1 C2/C3). `Hasher` is process-randomized; the new code seeds **SplitMix64** from the first 8 bytes of `SHA256(s.utf8)`, clamped to non-zero. Output is stable across runs (Task 9 Step 1).
- **`ErrorLifting` no longer uses `as? (any Error & Sendable)`** (loop-1 C4 + swift6 #3). `Sendable` is a marker protocol; conditional cast does not compile in strict mode. `lift(_:)` now takes plain `any Error` and maps only the four narrow error types; unknown errors return unchanged (Task 13).
- **`indexStream` never silently swallows errors** (loop-1 C5). The catch-all wraps any unknown `Error` in a Sendable `UnknownIndexError` carrier so `IndexFileError.scan(...)` always carries a payload — no file is ever dropped without a `.failed` event (Task 15).
- **`MockVectorStore.scan` propagates cancellation** (loop-1 C6). Captures the inner `Task` and wires `continuation.onTermination = { _ in task.cancel() }`; consumers dropping the stream cancel the producer immediately (Task 9).
- **`MockVectorStore.upsert` validates dimension** (loop-1 M9). Mirrors `SQLiteVectorStore`'s check so engine tests against the mock catch dimension regressions (Task 9).
- **`SQLiteVectorStore.pool` is explicitly `package`** (loop-1 M4). No more silent default-internal access (Task 19).
- **`CompactedSummary.proposedFilename` uses Foundation `Date.ISO8601FormatStyle`** (user pivot). No `DateFormatter` / `Locale` / `Calendar` dance — `dateStamp.formatted(.iso8601.year().month().day())` is locale-independent and UTC by default (Task 6).
- **`describe(_:some Error)` opens the existential at the call site** (user pivot, SE-0352). The error-rendering helper used by every `LocalizedError.errorDescription` no longer carries an `any Error` box; concrete error types are passed by opaque parameter (Task 7).
- **`errorDescription` renders user-readable strings** (loop-1 SwiftUI). `\(e)` interpolations are gone; payloads unwrap through `LocalizedError` then `NSError.localizedDescription`. `\(retryAfter as Any)` no longer leaks `Optional(...)` to alerts (Task 7).
- **Reduce invariant exposed as a pure helper** (loop-1 M10). `MemSearch.reduce(_:)` is a `package static` function; tests verify `index() == reduce(indexStream())` directly rather than via two-cold-runs equivalence (Task 15).
- **HTTP cancellation translation order** matches Apple's cooperative-cancel pattern (loop-1 SDK note). `try Task.checkCancellation()` first; only re-throw as `EmbeddingError.networkFailure` if the task wasn't cancelled (Task 23 Step 2).
- **`CancelStubProtocol` test mock** declares `@unchecked Sendable` with a documented justification (Task 24).
- **SwiftUI host-snippet compile gate** added so design-spec appendix drift fails the build, not visual review (Task 30 Step 2).
- **`MockVectorStore.cannedHits` is private**; only the documented `setCannedHits(_:)` setter mutates it (Task 9).

**Placeholder scan** — every "TBD"-shaped instruction in this plan is a deliberate prompt for the implementer (e.g. "fill in the manifest counts at fixture-pin time"), not a deferred design decision. The `mergeStore` / `mergeEmbedder` / `mergeChunking` field-merge helpers are spelled out inline in Task 29 Step 4 (no shape surprises).

**Type consistency** — `ChunkID(_ rawValue: String)` is `package init` everywhere; `Chunk.contentHash` matches Python's truncated SHA-256 (Task 5 Step 1); `MemSearch<V, E>: Sendable` unconditionally with `package` access on `store` and `embedder`; `SQLiteVectorStore` is `final class : Sendable` with `package let pool: DatabasePool`; `OpenAIEmbedder` is `final class : Sendable` over `URLSession.shared`; `MemSearchError.unimplemented(String)` and `LLMError.singleFlightViolation(any Error & Sendable)` carry forward verbatim from Phase 0 patches.

**Concurrency posture** — no `@unchecked Sendable` outside the documented `CancelStubProtocol` test exception; no `nonisolated(unsafe)`. `OSAllocatedUnfairLock<State>` for the mock's mutable state. Cancellation flows through public engine methods unchanged (`Swift.CancellationError`). `try Task.checkCancellation()` between files in `indexStream` and inside the HTTP cancellation translation. `MockVectorStore.scan` and `SQLiteVectorStore.scan` both wire `continuation.onTermination = { _ in task.cancel() }` so the consumer can stop the producer.

**Skill alignment** — Swift Testing throughout (no XCTest); structured concurrency for the indexStream Task; `AsyncThrowingStream.makeStream`-style continuation + `onTermination` task cancellation; `[weak self]` not needed in Phase 1 (no actors with retain-cycle risk; reserved for Phase 4 watcher); Sendable boundaries verified by the compile gate (Task 17) and by the SwiftUI host-snippet compile gate (Task 30).
