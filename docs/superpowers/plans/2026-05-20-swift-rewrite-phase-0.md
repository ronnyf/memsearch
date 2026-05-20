# Phase 0 — Spikes + Spec Patches Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Validate the three highest-risk external dependencies via throwaway spikes (GRDB + sqlite-vec + reader concurrency, swift-transformers Core ML + actor init shape, FoundationModels single-flight under stress); pin a Python ground-truth fixture for cross-checking later phases; ensure the design spec reflects every loop-2 patch plus any architectural pivots discovered.

**Architecture:** Spike code lives in `/tmp/memsearch-spikes/`, **never the repo**. Only result notes (`docs/superpowers/spikes/*.md`), the Python fixture (`tests/fixtures/python-baseline/`), and any spec deltas land in the repo. Phase 0 ends green when all three spikes have a result note, the fixture is pinned (with `python-top5.json.sha256`), and the design spec reflects any architectural pivots discovered during spikes.

**Tech Stack:** Swift 6 (Package.swift placeholder uses tools-version 6.4 with `swiftLanguageModes: [.v6]` + `ApproachableConcurrency`), GRDB.swift 7.x, sqlite-vec, swift-transformers, FoundationModels (macOS 26 SDK), Swift Testing for spike-internal asserts where structured testing helps, Python `memsearch` (this repo's existing implementation, ONNX bge-m3 provider) for the ground-truth fixture.

**Reference docs (must be read before starting):**
- `docs/superpowers/specs/2026-05-20-swift-rewrite-design.md` — the authoritative design spec; patches in Task 2 modify it directly.
- `docs/superpowers/specs/2026-05-20-swift-rewrite-phasing.md` — Phase 0 section is the source of truth for spike criteria; section "Spec patches during phases" governs Task 2.

**Hardware prerequisites:**
- A development Mac running **macOS 26** with Apple Intelligence enabled, signed in to an Apple ID with Apple Intelligence access. **Required for Task 4 (Spike 0c)** — non-skippable per the phasing doc. If the implementer's primary Mac is macOS 14/15, acquire a loaner or cloud runner before starting Phase 0.

---

## File Structure

### Repo files this plan creates

```
docs/superpowers/spikes/
├── 2026-05-20-spike-0a-sqlite-vec.md          # Task 2 result note
├── 2026-05-20-spike-0b-coreml-bge.md          # Task 3 result note
├── 2026-05-20-spike-0c-foundationmodels.md    # Task 4 result note
└── index.md                                    # Task 6 summary

tests/fixtures/python-baseline/
├── corpus/                                     # ~100 .md files (Task 5)
├── queries.json                                # 5–10 frozen queries
├── python-top5.json                            # Top-5 per query from Python memsearch
├── python-top5.json.sha256                     # Drift detector
└── manifest.json                               # Reproduction pins

docs/superpowers/phases/
└── phase-0-notes.md                            # Task 6: surprises, spec deltas, deferred items
```

### Repo files this plan may modify (only if Task 2 finds gaps)

```
docs/superpowers/specs/
└── 2026-05-20-swift-rewrite-design.md          # 7 listed patches + 2 derived inconsistencies
```

### Spike scratch (lives in /tmp, never committed)

```
/tmp/memsearch-spikes/
├── spike-0a/                                   # GRDB + sqlite-vec scratch SwiftPM package
├── spike-0b/                                   # Core ML + actor probe scratch
└── spike-0c/                                   # FoundationModels stress scratch
```

### Why nothing else in `Sources/` or `Package.swift` is touched

`Package.swift` and `Sources/Memsearch/Memsearch.swift` are pre-existing `swift package init` placeholders (untracked at Phase 0 start). Phase 0 explicitly does **not** put real Swift code into the repo — Phase 1 sets up the actual library packages per the design spec. Phase 0 leaves the placeholder alone.

---

## Task 1: Bootstrap directories

**Goal:** Make sure every output directory the plan needs exists, and confirm the operating environment is suitable. Pure scaffolding — no commits expected from this task alone.

**Files:**
- Create: `docs/superpowers/spikes/` (directory)
- Create: `docs/superpowers/phases/` (directory)
- Create: `tests/fixtures/python-baseline/` (directory)
- Create: `/tmp/memsearch-spikes/` (directory, scratch)

- [ ] **Step 1: Sanity-check toolchain and platform**

```bash
xcrun swift --version
sw_vers -productVersion
xcrun --show-sdk-version --sdk macosx
```

Expected output:
- Swift version `6.x` (≥ 6.0; design spec uses 6.0 toolchain floor, Package.swift placeholder is `swift-tools-version: 6.4`).
- macOS product version `26.x` for Spike 0c viability. **If macOS version is below 26.0:** stop and acquire macOS 26 hardware before continuing — Spike 0c is hard-required per the phasing doc.

- [ ] **Step 2: Create the three repo directories**

```bash
mkdir -p docs/superpowers/spikes docs/superpowers/phases tests/fixtures/python-baseline/corpus
```

- [ ] **Step 3: Create the scratch root**

```bash
mkdir -p /tmp/memsearch-spikes
```

- [ ] **Step 4: Verify directories exist**

```bash
ls -d docs/superpowers/spikes docs/superpowers/phases tests/fixtures/python-baseline/corpus /tmp/memsearch-spikes
```

Expected: all four paths print, no errors.

No commit yet — directories without content shouldn't be committed. Task 2 produces the first commit.

---

## Task 2: Verify and apply spec patches

**Goal:** Confirm all 7 phasing-doc patches landed in the design spec; apply any that didn't; **also** apply the two derived inconsistencies discovered during plan-writing (the spec's `callRespond` example only shows one catch clause where its own mapping table requires two; the `MockEmbeddingProvider` definition lacks the `latencyPerBatch` field that the testing-rule prose introduced).

**Files:**
- Modify (only if grep checks fail): `docs/superpowers/specs/2026-05-20-swift-rewrite-design.md`

- [ ] **Step 1: Verify patch 1 (`MemSearchError.unimplemented`)**

```bash
grep -nF 'case unimplemented(String)' docs/superpowers/specs/2026-05-20-swift-rewrite-design.md
```

Expected: a match inside the `public enum MemSearchError` block (around line 895), with the surrounding doc comment "Surface declared in an earlier phase, implementation arrives in a later phase."

If missing, edit the file to add the case after `case noSummarizerConfigured` inside `enum MemSearchError`:

```swift
    /// Surface declared in an earlier phase, implementation arrives in a later phase.
    /// String identifies the missing capability and the phase that adds it.
    case unimplemented(String)
```

- [ ] **Step 2: Verify patch 2 (`LLMError.singleFlightViolation`)**

```bash
grep -nF 'case singleFlightViolation(any Error & Sendable)' docs/superpowers/specs/2026-05-20-swift-rewrite-design.md
```

Expected: a match inside the `public enum LLMError` block (around line 613), with the surrounding doc comment about single-flight serialization.

If missing, add after `case modelFailure(...)` inside `enum LLMError`:

```swift
    /// Indicates that a summarizer's single-flight guard was bypassed —
    /// the underlying framework rejected an attempted concurrent request
    /// that the actor's serialization was supposed to prevent. Receiving
    /// this case in production indicates a bug in the summarizer actor
    /// (e.g., `FoundationModelsSummarizer`'s `inFlight: Task<String, Error>?`
    /// chain, or any future single-flight summarizer such as
    /// `MLXLocalSummarizer`). Tests `#expect` zero occurrences for each
    /// summarizer that uses single-flight serialization.
    case singleFlightViolation(any Error & Sendable)
```

- [ ] **Step 3: Verify patch 3 (`LanguageModelSession.Error` mapping table)**

```bash
grep -nF '`LanguageModelSession.Error`' docs/superpowers/specs/2026-05-20-swift-rewrite-design.md
```

Expected: a match in the mapping-tables section (around line 628), and the `.concurrentRequests → .singleFlightViolation` table row.

Also verify the prose note about two catch clauses:

```bash
grep -nF 'callRespond` should have **two catch clauses**' docs/superpowers/specs/2026-05-20-swift-rewrite-design.md
```

Expected: a match.

If either grep is empty, the table or prose is missing — add the second mapping table after the `GenerationError` table:

```markdown
| `LanguageModelSession.Error`                     | `LLMError`                  |
| ------------------------------------------------ | --------------------------- |
| `.concurrentRequests`                            | `.singleFlightViolation(_)` |
| (other cases)                                    | `.modelFailure(...)`        |
```

And the prose:

```markdown
`callRespond` should have **two catch clauses** (`catch let e as LanguageModelSession.GenerationError` and `catch let e as LanguageModelSession.Error`) so neither enum slips into a generic `catch` and loses its type information.
```

- [ ] **Step 4: Verify patch 4 (HTTP cancellation pattern in cancellation table)**

```bash
grep -n 'try Task.checkCancellation()' docs/superpowers/specs/2026-05-20-swift-rewrite-design.md
```

Expected: at least one match in the "Cancellation granularity per embedder" table (around line 377), describing the `URLError(.cancelled)` → `try Task.checkCancellation()` → `EmbeddingError.networkFailure(URLError)` rethrow chain.

If the row isn't there, replace the HTTP-row description with the long-form text from the phasing doc patch 4.

- [ ] **Step 5: Verify patch 5 (Platforms claim with iOS/visionOS compile-only)**

```bash
grep -nF 'compile-only verified in v1' docs/superpowers/specs/2026-05-20-swift-rewrite-design.md
```

Expected: a match in the Platforms section (around line 47), with surrounding text about iOS-runtime validation deferred to v2.

If missing, replace the iOS/visionOS bullet with the phasing-doc patch 5 wording.

- [ ] **Step 6: Verify patch 6 (v1-status banner in SwiftUI integration appendix)**

```bash
grep -nF 'v1 status' docs/superpowers/specs/2026-05-20-swift-rewrite-design.md
```

Expected: a match inside the "SwiftUI integration (host pattern)" section (around line 1023), framed as a blockquote callout.

If missing, prepend a blockquote at the top of that section:

```markdown
> **v1 status:** macOS-validated. iOS hosts can compile this pattern in v1,
> but iOS-runtime behavior — particularly the watcher path (`mem.watch()`),
> security-scoped URL handling around `mem.paths` and `appendSummary`'s
> `outputDirectory`, and backgrounding interactions — is **deferred to v2**.
> Expect to discover and report iOS-runtime issues. See the phasing doc's
> "Deferred to v2" and "v2 iOS validation backlog" sections.
```

- [ ] **Step 7: Verify patch 7a (testing rule prose mentions Task.sleep + latencyPerBatch)**

```bash
grep -nF 'latencyPerBatch: Duration?' docs/superpowers/specs/2026-05-20-swift-rewrite-design.md
```

Expected: at least one match in the Testing/Determinism subsection (around line 992).

If missing, replace the "Determinism" paragraph with the phasing-doc patch 7 wording.

- [ ] **Step 8: Verify patch 7b — DERIVED — `MockEmbeddingProvider` State struct includes `latencyPerBatch`**

The phasing-doc patch 7 promises the mock "gains a `latencyPerBatch: Duration?` field." The spec's prose was updated; the **mock code definition** at lines 947–967 was not.

```bash
awk '/package final class MockEmbeddingProvider/,/^}/' docs/superpowers/specs/2026-05-20-swift-rewrite-design.md | grep -F 'latencyPerBatch'
```

Expected: a match inside the `MockEmbeddingProvider` definition (specifically inside the `State` struct or the init signature).

If missing, edit the mock definition so it reads:

```swift
package final class MockEmbeddingProvider: EmbeddingProvider {
    package nonisolated let modelName: String = "mock"
    package nonisolated let dimension: Int

    private let lock = OSAllocatedUnfairLock<State>(initialState: .init())
    package struct State {
        var injectedFailures: [String: EmbeddingError] = [:]
        var latencyPerBatch: Duration? = nil
    }

    package init(dimension: Int = 8,
                 injectedFailures: [String: EmbeddingError] = [:],
                 latencyPerBatch: Duration? = nil) {
        self.dimension = dimension
        lock.withLock {
            $0.injectedFailures = injectedFailures
            $0.latencyPerBatch = latencyPerBatch
        }
    }

    package func embed(_ texts: [String]) async throws -> [Embedding] {
        let (failures, latency) = lock.withLock { ($0.injectedFailures, $0.latencyPerBatch) }
        if let latency { try await Task.sleep(for: latency) }
        if let first = texts.first, let injected = failures[first] {
            throw injected
        }
        return try texts.map { try Embedding(values: hashToFloats($0, dim: dimension), expectedDimension: dimension) }
    }
}
```

The `Task.sleep(for:)` call before the failure check is what gives Phase 1's cancellation tests a documented suspension point — the cancellation lands during the sleep and surfaces as `CancellationError`, not as the injected failure.

- [ ] **Step 9: Verify patch 3b — DERIVED — `callRespond` example shows TWO catch clauses**

The mapping-tables prose (patch 3, verified in Step 3) requires two catch clauses. The `FoundationModelsSummarizer` example at lines 584–590 shows only one.

```bash
awk '/private func callRespond/,/^    }/' docs/superpowers/specs/2026-05-20-swift-rewrite-design.md | grep -c 'catch let e as'
```

Expected: `2` (one for `LanguageModelSession.GenerationError`, one for `LanguageModelSession.Error`).

If the count is `1`, edit the example's `callRespond` body so it reads:

```swift
    private func callRespond(_ prompt: String) async throws -> String {
        do { return try await session.respond(to: prompt).content }
        catch let e as LanguageModelSession.GenerationError {
            throw mapGenerationError(e)
        }
        catch let e as LanguageModelSession.Error {
            throw mapSessionError(e)
        }
    }
```

(`mapGenerationError` and `mapSessionError` are private helpers implied by the mapping tables; their bodies are not part of the spec example.)

- [ ] **Step 10: If any patches were applied, commit**

If any of Steps 1–9 made edits, commit them as a single spec patch:

```bash
git add docs/superpowers/specs/2026-05-20-swift-rewrite-design.md
git commit -m "docs: spec patch — close gaps before Phase 0 spikes"
```

If every grep matched (no edits), skip the commit — the spec is already correct, and there is nothing to record.

- [ ] **Step 11: Sanity-grep one more time after edits**

Repeat the greps from Steps 1–9 in a single command to make sure every patch is now present:

```bash
SPEC=docs/superpowers/specs/2026-05-20-swift-rewrite-design.md
grep -cF 'case unimplemented(String)' "$SPEC"            # expect ≥1
grep -cF 'case singleFlightViolation(any Error & Sendable)' "$SPEC"  # expect ≥1
grep -cF '`LanguageModelSession.Error`' "$SPEC"          # expect ≥1
grep -cF 'try Task.checkCancellation()' "$SPEC"          # expect ≥1
grep -cF 'compile-only verified in v1' "$SPEC"           # expect ≥1
grep -cF 'v1 status' "$SPEC"                              # expect ≥1
grep -cF 'latencyPerBatch: Duration?' "$SPEC"            # expect ≥1
awk '/private func callRespond/,/^    }/' "$SPEC" | grep -c 'catch let e as'   # expect 2
```

Every line should print a non-zero number; the last must print exactly `2`. If any line prints `0`, return to that step's "if missing" branch.

---

## Task 3: Spike 0a — GRDB 7.x + sqlite-vec extension load + reader concurrency

**Goal:** Prove the `MemSearchSQLite` design's three load-bearing assumptions: (1) macOS-system SQLite via GRDB can load the `vec0` extension via `Configuration.prepareDatabase`, (2) a `vec0` virtual table accepts insert and KNN SELECT, and (3) GRDB's `DatabasePool` actually parallelizes readers when `vec0` is loaded — the design's `final class : Sendable` choice over an actor depends on this.

**Done criteria (from phasing doc):**
- KNN SELECT returns the inserted vector.
- 8 parallel reader Tasks all return correct results AND wall-clock is meaningfully sub-linear in N.

**Failure modes:** the phasing doc enumerates four (a–d). If any hit, follow the fallout step at the end of this task.

**Files:**
- Create (scratch, not committed): `/tmp/memsearch-spikes/spike-0a/Package.swift`
- Create (scratch, not committed): `/tmp/memsearch-spikes/spike-0a/Sources/Spike0a/main.swift`
- Create: `docs/superpowers/spikes/2026-05-20-spike-0a-sqlite-vec.md`

- [ ] **Step 1: Scaffold the scratch package**

```bash
mkdir -p /tmp/memsearch-spikes/spike-0a/Sources/Spike0a
cd /tmp/memsearch-spikes/spike-0a
swift package init --type executable --name Spike0a
```

This creates a default `Package.swift` and `Sources/Spike0a/Spike0a.swift`. We'll overwrite both.

- [ ] **Step 2: Write `Package.swift` with GRDB.swift 7.x and sqlite-vec deps**

Overwrite `/tmp/memsearch-spikes/spike-0a/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Spike0a",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        // sqlite-vec is research-pending. The Swift ecosystem options as of
        // 2026-05 are: (a) sqlite-vec's official Swift bindings via SPM if
        // they exist, (b) a binary target + linkerSettings for the C
        // amalgamation, (c) bundling sqlite-vec.c directly as a .target.
        // Try (a) first; if it fails, the spike implementer falls back
        // to (b) or (c). Document the chosen path in the result note.
        // Placeholder URL — implementer replaces with the real sqlite-vec
        // SPM URL or removes if going with the C-amalgamation route.
        // .package(url: "https://github.com/asg017/sqlite-vec.git", from: "0.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "Spike0a",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                // .product(name: "SQLiteVec", package: "sqlite-vec"),
            ]
        )
    ]
)
```

**Note for the implementer:** sqlite-vec distribution path is an open question per the design spec's "Open questions" section. This spike is the appropriate place to land that decision. Document the working integration path in the result note.

- [ ] **Step 3: Write `main.swift` with the three sub-experiments**

Overwrite `/tmp/memsearch-spikes/spike-0a/Sources/Spike0a/main.swift`:

```swift
import Foundation
import GRDB

// Spike 0a — GRDB 7.x + sqlite-vec + reader concurrency.
// Prints PASS / FAIL lines for each sub-criterion. Exit 0 on full pass; non-zero on any fail.

let dbPath = "/tmp/memsearch-spikes/spike-0a/test.db"
try? FileManager.default.removeItem(atPath: dbPath)

var config = Configuration()
config.prepareDatabase { db in
    try db.execute(sql: "SELECT load_extension('vec0')")
}

let pool: DatabasePool
do {
    pool = try DatabasePool(path: dbPath, configuration: config)
} catch {
    print("FAIL: DatabasePool init failed: \(error)")
    print("Likely failure mode (a): macOS system SQLite has extension loading disabled.")
    print("Pivots to consider: SQLite3-static SPM dep, GRDB SQLiteCustomBuild, or drop sqlite-vec entirely.")
    exit(1)
}

// --- Sub-criterion 1: vec0 virtual table + INSERT + KNN SELECT
do {
    try await pool.write { db in
        try db.execute(sql: """
            CREATE VIRTUAL TABLE chunks USING vec0(embedding float[1024])
        """)
        let vec = Data(bytes: (0..<1024).map { Float($0) / 1024.0 }, count: 1024 * MemoryLayout<Float>.size)
        try db.execute(
            sql: "INSERT INTO chunks(rowid, embedding) VALUES (?, ?)",
            arguments: [1, vec]
        )
    }

    let hits: [Int64] = try await pool.read { db in
        let queryVec = Data(bytes: (0..<1024).map { Float($0) / 1024.0 }, count: 1024 * MemoryLayout<Float>.size)
        let rows = try Row.fetchAll(db, sql: """
            SELECT rowid FROM chunks
            WHERE embedding MATCH ?
            ORDER BY distance LIMIT 5
        """, arguments: [queryVec])
        return rows.map { $0["rowid"] as Int64 }
    }

    guard hits == [1] else {
        print("FAIL: KNN SELECT returned \(hits) (expected [1])")
        exit(1)
    }
    print("PASS: KNN SELECT returns inserted vector")
} catch {
    print("FAIL: KNN sub-experiment threw: \(error)")
    exit(1)
}

// --- Sub-criterion 2: 8-way reader concurrency, parallel scaling.
// Bulk up the table with 10k vectors so per-read latency is non-trivial.
try await pool.write { db in
    for i in 2...10_000 {
        let vec = Data(bytes: (0..<1024).map { _ in Float.random(in: -1...1) },
                       count: 1024 * MemoryLayout<Float>.size)
        try db.execute(
            sql: "INSERT INTO chunks(rowid, embedding) VALUES (?, ?)",
            arguments: [i, vec]
        )
    }
}

let probeVec = Data(bytes: (0..<1024).map { _ in Float.random(in: -1...1) },
                    count: 1024 * MemoryLayout<Float>.size)

func runOneRead() async throws -> Int {
    try await pool.read { db in
        let rows = try Row.fetchAll(db, sql: """
            SELECT rowid FROM chunks
            WHERE embedding MATCH ?
            ORDER BY distance LIMIT 50
        """, arguments: [probeVec])
        return rows.count
    }
}

// Serial baseline: 8 reads, one after another.
let serialStart = ContinuousClock.now
for _ in 0..<8 {
    _ = try await runOneRead()
}
let serialElapsed = ContinuousClock.now - serialStart
print("Serial 8 reads: \(serialElapsed)")

// Concurrent: 8 reads in parallel via TaskGroup.
let concurrentStart = ContinuousClock.now
try await withThrowingTaskGroup(of: Int.self) { group in
    for _ in 0..<8 {
        group.addTask { try await runOneRead() }
    }
    var seen = 0
    for try await count in group {
        guard count == 50 else {
            print("FAIL: concurrent reader returned \(count) rows (expected 50)")
            exit(1)
        }
        seen += 1
    }
    guard seen == 8 else {
        print("FAIL: only \(seen)/8 concurrent readers returned")
        exit(1)
    }
}
let concurrentElapsed = ContinuousClock.now - concurrentStart
print("Concurrent 8 reads: \(concurrentElapsed)")

// "Meaningfully sub-linear" — concurrent should beat serial by a clear margin.
// Threshold: concurrent < serial * 0.6 (i.e. ≥ 40% speedup). Tune in the result note
// if the measurement is noisy.
let speedup = serialElapsed / concurrentElapsed
print("Speedup: \(speedup)x")
guard concurrentElapsed < serialElapsed * 0.6 else {
    print("FAIL: concurrent reads are not meaningfully sub-linear")
    print("Likely failure mode (d): GRDB pool readers do not parallelize with vec0 loaded.")
    print("Pivot: switch SQLiteVectorStore from final class : Sendable to actor (spec patch).")
    exit(1)
}
print("PASS: concurrent reads scale sub-linearly")

print("ALL PASS")
```

**Concurrency-pro nuances baked in:**
- `withThrowingTaskGroup` over `Task {}` loop — structured concurrency, propagates cancellation, awaits all children.
- `ContinuousClock` instead of `Date` for measurement — monotonic, immune to wall-clock adjustments.

- [ ] **Step 4: Build and run the spike**

```bash
cd /tmp/memsearch-spikes/spike-0a
swift run
```

Expected output ends with `ALL PASS` and printed serial/concurrent timings showing a clear speedup.

If a `FAIL:` line prints, jump to Step 7 below to record the failure in the result note (and apply any spec pivot).

- [ ] **Step 5: Capture timing numbers and the chosen sqlite-vec integration path**

Note (in your scratchpad, for the result note in Step 6):
- Exact serial duration, concurrent duration, speedup factor.
- Which of (a)/(b)/(c) sqlite-vec distribution path actually worked — SPM dep URL + version, OR binary target details, OR vendored amalgamation file.
- macOS version reported by `sw_vers`.
- GRDB version locked by SPM resolution (`cat Package.resolved | grep -A3 GRDB`).

- [ ] **Step 6: Write the result note**

Create `docs/superpowers/spikes/2026-05-20-spike-0a-sqlite-vec.md` with this template (substitute real numbers / paths / errors):

```markdown
# Spike 0a — GRDB 7.x + sqlite-vec + reader concurrency

**Date:** 2026-05-20
**Phase:** 0
**Risk it covers:** macOS system SQLite extension-loading + GRDB DatabasePool reader concurrency under sqlite-vec.

## Environment

- macOS: <e.g. 26.0>
- Swift: <e.g. 6.4>
- GRDB.swift: <e.g. 7.x.y, from Package.resolved>
- sqlite-vec integration path: <SPM dep URL, OR binary target, OR vendored amalgamation>

## Result

**Outcome:** PASS / FAIL (short verdict)

### Sub-criterion 1 — vec0 KNN

PASS / FAIL. KNN SELECT returned <list> (expected `[1]`).

### Sub-criterion 2 — Reader concurrency

- Serial 8 reads: <e.g. 1.42 s>
- Concurrent 8 reads: <e.g. 0.38 s>
- Speedup: <e.g. 3.7x>
- PASS / FAIL on the < 0.6 × serial threshold.

## Spec implications

- <"None — design holds." OR list any pivots applied to design spec.>

If failure mode (a) [extension loading disabled]: list the chosen workaround (SQLite3-static / SQLiteCustomBuild / drop sqlite-vec) and the spec edit applied.

If failure mode (c) [drop sqlite-vec entirely]: document that Phase 1's `MemSearchSQLite` deliverables now use brute-force cosine over BLOBs instead of vec0 KNN; record the spec edit; flag that Phase 1 effort estimate must be re-baselined before that phase starts.

If failure mode (d) [reader concurrency fails]: document the actor-vs-class pivot for `SQLiteVectorStore`; record the spec edit.

## Notes

<Anything surprising; integration friction; deferred items.>
```

- [ ] **Step 7: If a failure mode hit, apply spec patch and recommit**

Per the phasing doc's Spec drift discipline section:
1. Patch `docs/superpowers/specs/2026-05-20-swift-rewrite-design.md` with the architectural pivot.
2. Commit with `docs: spec patch — Spike 0a <failure mode> pivot`.
3. Update the result note's "Spec implications" section to reference the commit hash.

If Phase 1's deliverables would change (failure mode c), also note in the result note that Phase 1's plan must be regenerated before Phase 1 starts.

- [ ] **Step 8: Commit the result note**

```bash
git add docs/superpowers/spikes/2026-05-20-spike-0a-sqlite-vec.md
git commit -m "docs: spike 0a result — GRDB + sqlite-vec + reader concurrency"
```

The scratch directory `/tmp/memsearch-spikes/spike-0a/` is **not** committed.

---

## Task 4: Spike 0b — swift-transformers Core ML embedder + actor init shape

**Goal:** Prove (1) swift-transformers can load a Core ML embedding model end-to-end (BGE-M3 preferred, `all-MiniLM-L6-v2` fallback), and (2) the design's actor init shape — `nonisolated let dimension: Int` set inside `async throws init` and read from a non-isolated context — actually compiles in Swift 6 strict mode. The `EmbeddingProvider` protocol's `nonisolated var dimension: Int { get }` requirement depends on this.

**Done criteria (from phasing doc):**
- An embedding model loads end-to-end and produces a vector for `"hello world"` whose dimension matches the model's documented dimension.
- A minimal `actor TestEmbedder` with `nonisolated let dimension: Int` set in `async throws init` compiles AND `someEmbedder.dimension` reads correctly from non-isolated context.

**Files:**
- Create (scratch): `/tmp/memsearch-spikes/spike-0b/Package.swift`
- Create (scratch): `/tmp/memsearch-spikes/spike-0b/Sources/Spike0b/main.swift`
- Create: `docs/superpowers/spikes/2026-05-20-spike-0b-coreml-bge.md`

- [ ] **Step 1: Scaffold the scratch package**

```bash
mkdir -p /tmp/memsearch-spikes/spike-0b/Sources/Spike0b
cd /tmp/memsearch-spikes/spike-0b
swift package init --type executable --name Spike0b
```

- [ ] **Step 2: Write `Package.swift` with swift-transformers**

Overwrite `/tmp/memsearch-spikes/spike-0b/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Spike0b",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "0.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "Spike0b",
            dependencies: [
                .product(name: "Transformers", package: "swift-transformers"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        )
    ]
)
```

The `.swiftLanguageMode(.v6)` line is critical — it ensures the actor probe runs under the same strict-concurrency rules as the real library will.

- [ ] **Step 3: Resolve a working model directory**

The scratch needs an actual on-disk model. Two options — try them in order:

1. **Hugging Face cache via swift-transformers' `Hub` helper**: if swift-transformers ships a `Hub.snapshot(from: "BAAI/bge-m3")` style API in May 2026, use it. This downloads the tokenizer + Core ML package into `~/.cache/huggingface/hub/`.
2. **Manual download**: `git lfs clone https://huggingface.co/BAAI/bge-m3 /tmp/memsearch-spikes/spike-0b/models/bge-m3`. Verify `tokenizer.json`, `tokenizer_config.json`, and a `*.mlpackage` directory exist after the clone.

If BGE-M3 is unavailable in Core ML format, fall back to `sentence-transformers/all-MiniLM-L6-v2` (clone path: `/tmp/memsearch-spikes/spike-0b/models/MiniLM-L6`). MiniLM produces 384-dim vectors instead of BGE-M3's 1024.

Record the resolution path in the scratchpad — the result note must capture which model worked.

- [ ] **Step 4: Write `main.swift` with both sub-experiments**

Overwrite `/tmp/memsearch-spikes/spike-0b/Sources/Spike0b/main.swift`:

```swift
import Foundation
import CoreML
import Transformers // swift-transformers umbrella module name; adjust if the real product is `Tokenizers`/`Hub` etc.

// Spike 0b — Core ML embedding model + actor init shape probe.

let modelFolderPath: String
let expectedDimension: Int

// Resolve which model is on disk. Prefer BGE-M3, fall back to MiniLM.
let bgeFolder = "/tmp/memsearch-spikes/spike-0b/models/bge-m3"
let miniLMFolder = "/tmp/memsearch-spikes/spike-0b/models/MiniLM-L6"
if FileManager.default.fileExists(atPath: bgeFolder) {
    modelFolderPath = bgeFolder
    expectedDimension = 1024
} else if FileManager.default.fileExists(atPath: miniLMFolder) {
    modelFolderPath = miniLMFolder
    expectedDimension = 384
} else {
    print("FAIL: no model folder on disk. Run Step 3 of the plan first.")
    exit(1)
}
let modelFolderURL = URL(fileURLWithPath: modelFolderPath)

// --- Sub-experiment A: end-to-end embed.
do {
    let tokenizer = try await AutoTokenizer.from(modelFolder: modelFolderURL)
    let mlpackageURL = modelFolderURL.appendingPathComponent("model.mlpackage")
    guard FileManager.default.fileExists(atPath: mlpackageURL.path) else {
        print("FAIL: \(mlpackageURL.path) missing — model folder lacks Core ML package")
        exit(1)
    }
    let model = try MLModel(contentsOf: mlpackageURL)

    let tokens = tokenizer.encode(text: "hello world")
    // Real inference plumbing varies by model — input shape, key names, postprocessing
    // (mean-pool, normalize). The spike just needs to prove the load + a forward pass
    // compiles and runs. Implementer fills in the specifics for the chosen model.
    let inputs = try makeMLInput(tokens: tokens, model: model)
    let prediction = try model.prediction(from: inputs)
    let dim = extractDimension(prediction: prediction, model: model)

    guard dim == expectedDimension else {
        print("FAIL: model returned dim=\(dim) (expected \(expectedDimension))")
        exit(1)
    }
    print("PASS: end-to-end embed produced dim=\(dim)")
} catch {
    print("FAIL: model load/embed threw: \(error)")
    exit(1)
}

// --- Sub-experiment B: actor init shape probe.
//
// This is the LOAD-BEARING test. The design spec's CoreMLEmbedder declares
//   public actor CoreMLEmbedder: EmbeddingProvider {
//       public nonisolated let dimension: Int
//       public nonisolated let modelName: String
//       private let model: MLModel
//       private let tokenizer: Tokenizer
//       public init(modelFolder: URL, modelName: String, dimension: Int) async throws { ... }
//   }
// We need to prove this exact shape compiles AND that a non-isolated caller
// can read .dimension without `await`.

actor TestEmbedder {
    nonisolated let dimension: Int
    nonisolated let modelName: String
    private let model: MLModel
    private let tokenizer: any Tokenizer

    init(modelFolder: URL, modelName: String, dimension: Int) async throws {
        // The design spec mandates this init order: async work first, then store.
        let tokenizer = try await AutoTokenizer.from(modelFolder: modelFolder)
        let model = try MLModel(contentsOf: modelFolder.appendingPathComponent("model.mlpackage"))
        self.tokenizer = tokenizer
        self.model = model
        self.modelName = modelName
        self.dimension = dimension
    }
}

let probe = try await TestEmbedder(
    modelFolder: modelFolderURL,
    modelName: "spike-probe",
    dimension: expectedDimension
)

// Read .dimension from a non-isolated context. If the property is correctly
// nonisolated, this compiles WITHOUT `await`.
let nonisolatedRead: Int = probe.dimension
guard nonisolatedRead == expectedDimension else {
    print("FAIL: non-isolated read returned \(nonisolatedRead) (expected \(expectedDimension))")
    exit(1)
}
print("PASS: actor probe — nonisolated dimension=\(nonisolatedRead)")

print("ALL PASS")

// MARK: - Tiny helpers (model-specific; implementer fills in)

func makeMLInput(tokens: [Int], model: MLModel) throws -> MLFeatureProvider {
    fatalError("Implementer fills in the model-specific input construction")
}

func extractDimension(prediction: MLFeatureProvider, model: MLModel) -> Int {
    fatalError("Implementer fills in the model-specific output extraction")
}
```

**Concurrency-pro nuance:** The actor probe stores `tokenizer` and `model` as actor-isolated `private let`s populated inside `async throws init` (after the async work completes). `dimension` and `modelName` are `nonisolated let` because they're plain values. This is the only way to satisfy a sync protocol requirement (`nonisolated var dimension: Int { get }`) from inside an actor — per the design spec's "`dimension`/`modelName` are `nonisolated`" note.

**If the actor probe fails to compile:** that's failure mode for Spike 0b. The phasing doc's pivot is `static func make(folder:) async throws -> Self` factory pattern. Apply that to the design spec's `CoreMLEmbedder` and `ONNXEmbedder` definitions; document the cascade (every CoreMLEmbedder construction site changes from `try await CoreMLEmbedder(...)` to `try await CoreMLEmbedder.make(...)`). This affects Phase 2 + Phase 5 + the entire CLI dispatch.

- [ ] **Step 5: Build and run**

```bash
cd /tmp/memsearch-spikes/spike-0b
swift build
```

If the build alone fails on the actor probe, that's the actor-shape failure. Stop and apply the static-factory pivot per Step 4's commentary.

If build succeeds:

```bash
swift run
```

Expected: `ALL PASS`. If any line prints `FAIL:`, jump to Step 7.

- [ ] **Step 6: Capture model + dependency facts**

For the result note:
- Actual model used (BGE-M3 vs MiniLM-L6 vs other) and its source URL.
- swift-transformers version locked by SPM.
- Whether the actor probe compiled clean or required the static-factory pivot.

- [ ] **Step 7: Write the result note**

Create `docs/superpowers/spikes/2026-05-20-spike-0b-coreml-bge.md`:

```markdown
# Spike 0b — swift-transformers Core ML + actor init shape

**Date:** 2026-05-20
**Phase:** 0
**Risk it covers:** swift-transformers Core ML availability for default embedder + actor init shape compiles under Swift 6 strict concurrency.

## Environment

- macOS: <version>
- Swift: <version>
- swift-transformers: <SPM version>
- Model: <BGE-M3 | all-MiniLM-L6-v2 | other> (<source URL>)
- Expected dimension: <1024 | 384 | other>

## Result

**Outcome:** PASS / FAIL (short verdict)

### Sub-experiment A — end-to-end embed

PASS / FAIL. Embed of `"hello world"` produced dim=<n> (expected <m>).

### Sub-experiment B — actor init shape

PASS / FAIL. `actor TestEmbedder` with `nonisolated let dimension: Int` compiled and a non-isolated read returned the expected value.

If sub-experiment B failed: document the static-factory pivot applied (`static func make(folder:) async throws -> Self`) and the spec edit; flag that every `CoreMLEmbedder(...)` construction site needs `CoreMLEmbedder.make(...)` in Phase 2+.

## Spec implications

- Default Core ML embedding model identifier resolves to `<exact ID>` for v1 (per Risks → "swift-transformers BGE-M3 Core ML availability"). If MiniLM-L6 was the fallback, document the upgrade path to BGE-M3 (deferred to v2 if/when shipped).
- <"Actor init shape OK" OR "Static-factory pivot applied — see commit <hash>">

## Notes

<Anything surprising; integration friction; deferred items.>
```

- [ ] **Step 8: If sub-experiment B failed, apply spec patch**

Edit the design spec's `CoreMLEmbedder` definition (and the matching `ONNXEmbedder` if Spike 0b's pivot generalizes) to use the static-factory pattern. Commit with `docs: spec patch — Spike 0b actor-shape fallback`.

Update the result note's "Spec implications" with the commit hash.

- [ ] **Step 9: Commit the result note**

```bash
git add docs/superpowers/spikes/2026-05-20-spike-0b-coreml-bge.md
git commit -m "docs: spike 0b result — Core ML + actor init shape"
```

---

## Task 5: Spike 0c — FoundationModels single-flight stress test (HARD-REQUIRED)

**Goal:** Validate the design spec's chained-Task single-flight pattern under stress: 10 concurrent callers × 100 iterations = 1000 calls. The spec's `FoundationModelsSummarizer` is the riskiest concurrency primitive in v1; discovering a race during Phase 6 is too late.

**Done criteria (from phasing doc):**
- (a) **Zero `LanguageModelSession.Error.concurrentRequests` errors** over the 1000 calls. Every framework error is caught and classified.
- (b) **FIFO arrival → FIFO completion**: requests complete in arrival order. Stronger property: no two requests have overlapping `(start, end)` intervals — i.e., the chained-Task `inFlight` actually serializes the framework call.

**Hard precondition:** macOS 26 with Apple Intelligence enabled. **Non-skippable.** If macOS 26 hardware is unavailable, acquire it (loaner Mac, cloud runner) before this task starts.

**Files:**
- Create (scratch): `/tmp/memsearch-spikes/spike-0c/Package.swift`
- Create (scratch): `/tmp/memsearch-spikes/spike-0c/Sources/Spike0c/main.swift`
- Create: `docs/superpowers/spikes/2026-05-20-spike-0c-foundationmodels.md`

- [ ] **Step 1: Confirm Apple Intelligence runtime**

```bash
sw_vers -productVersion         # expect 26.x
xcrun --show-sdk-version --sdk macosx   # expect 26.x SDK
```

Then verify Apple Intelligence is enabled in System Settings → Apple Intelligence & Siri. If it's not enabled, this spike will short-circuit on `SystemLanguageModel.default.isAvailable == false`.

- [ ] **Step 2: Scaffold the scratch package**

```bash
mkdir -p /tmp/memsearch-spikes/spike-0c/Sources/Spike0c
cd /tmp/memsearch-spikes/spike-0c
swift package init --type executable --name Spike0c
```

- [ ] **Step 3: Write `Package.swift`**

Overwrite `/tmp/memsearch-spikes/spike-0c/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Spike0c",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Spike0c",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        )
    ]
)
```

`FoundationModels` is a system framework on macOS 26 — no SPM dep needed.

- [ ] **Step 4: Write the StressActor (the spec's exact pattern + telemetry)**

Overwrite `/tmp/memsearch-spikes/spike-0c/Sources/Spike0c/main.swift`:

```swift
import Foundation
import FoundationModels

// Spike 0c — FoundationModels single-flight stress test.
// Implements the design spec's exact chained-Task pattern, instrumented
// with (start, end) timestamps captured INSIDE callRespond (per phasing doc:
// "not at caller-spawn time, which is racy across Task initiation").

@available(macOS 26, *)
actor StressActor {
    private let session: LanguageModelSession
    private var inFlight: Task<String, Error>?

    private(set) var intervals: [(ContinuousClock.Instant, ContinuousClock.Instant)] = []
    private(set) var concurrentRequestErrors: Int = 0
    private(set) var otherErrors: [String] = []   // String descriptions; spike doesn't need typed retention

    init?(instructions: String) {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        self.session = LanguageModelSession(instructions: instructions)
    }

    func summarize(prompt: String) async throws -> String {
        let prior = inFlight
        let task = Task<String, Error> { [weak self] in
            if let prior { _ = try? await prior.value }
            guard let self else { throw CancellationError() }
            return try await self.callRespond(prompt)
        }
        inFlight = task                                 // synchronous on actor — no reentrancy window
        defer { if inFlight === task { inFlight = nil } }
        return try await task.value
    }

    private func callRespond(_ prompt: String) async throws -> String {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let result = try await session.respond(to: prompt).content
            let end = clock.now
            intervals.append((start, end))
            return result
        } catch let e as LanguageModelSession.GenerationError {
            otherErrors.append("GenerationError: \(e)")
            throw e
        } catch let e as LanguageModelSession.Error {
            // The spec's mapping says `.concurrentRequests` lives on this enum.
            // If the framework signals it, single-flight serialization failed.
            switch e {
            case .concurrentRequests:
                concurrentRequestErrors += 1
            default:
                break
            }
            otherErrors.append("Error: \(e)")
            throw e
        }
    }

    func snapshot() -> (
        intervals: [(ContinuousClock.Instant, ContinuousClock.Instant)],
        concurrentRequestErrors: Int,
        otherErrors: [String]
    ) {
        (intervals, concurrentRequestErrors, otherErrors)
    }
}

@main
@available(macOS 26, *)
struct Spike0cMain {
    static func main() async throws {
        guard let actor = StressActor(instructions: "You summarize text concisely.") else {
            print("FAIL: SystemLanguageModel.default.isAvailable == false. Apple Intelligence not enabled, or device unsupported.")
            exit(1)
        }

        let concurrent = 10
        let iterations = 100
        let total = concurrent * iterations

        await withTaskGroup(of: Void.self) { group in
            for tid in 0..<concurrent {
                group.addTask {
                    for i in 0..<iterations {
                        let prompt = "Worker \(tid) iter \(i): summarize this in one sentence: hello world."
                        // Errors are recorded inside the actor; we do not need to surface here.
                        _ = try? await actor.summarize(prompt: prompt)
                    }
                }
            }
        }

        let snap = await actor.snapshot()
        let succeeded = snap.intervals.count
        print("Total calls: \(total)")
        print("Succeeded: \(succeeded)")
        print("ConcurrentRequests errors: \(snap.concurrentRequestErrors)")
        print("Other errors: \(snap.otherErrors.count)")

        // --- Done criterion (a): zero concurrentRequests errors.
        guard snap.concurrentRequestErrors == 0 else {
            print("FAIL: \(snap.concurrentRequestErrors) concurrentRequests errors over \(total) calls")
            print("Pivot: revise the chained-Task pattern; consult Apple sample code; consider switching to a different serialization primitive.")
            exit(1)
        }
        print("PASS: zero concurrentRequests errors")

        // --- Done criterion (b): FIFO + non-overlapping intervals.
        // Since `intervals` is appended in completion order (inside callRespond
        // after the await), the natural index order = completion order.
        // Sort by start time to derive arrival order.
        let sortedByStart = snap.intervals.sorted(by: { $0.0 < $1.0 })

        // Non-overlapping: each interval's start must be ≥ the previous interval's end.
        for i in 1..<sortedByStart.count {
            let prev = sortedByStart[i-1]
            let curr = sortedByStart[i]
            guard prev.1 <= curr.0 else {
                print("FAIL: overlapping intervals at sorted index \(i) — prev=(\(prev.0)..\(prev.1)), curr=(\(curr.0)..\(curr.1))")
                print("Pivot: chained-Task pattern does not actually serialize the framework call. Spec single-flight pattern is wrong.")
                exit(1)
            }
        }

        // FIFO arrival → FIFO completion: insertion order should equal start-sorted order.
        for i in 0..<snap.intervals.count {
            let original = snap.intervals[i]
            let sorted = sortedByStart[i]
            guard original.0 == sorted.0 && original.1 == sorted.1 else {
                print("FAIL: FIFO order violated at index \(i)")
                print("Pivot: arrival order does not equal completion order — chained-Task chain is not serializing strictly enough.")
                exit(1)
            }
        }
        print("PASS: FIFO + non-overlapping intervals")

        print("ALL PASS")
    }
}
```

**Concurrency-pro nuances baked in:**
- `withTaskGroup(of: Void.self)` for the 10 workers — structured concurrency, propagates cancellation.
- `[weak self]` in the chained Task closure (per design spec) — `LanguageModelSession` is not `Sendable`, so we capture the actor weakly and re-enter via `self.callRespond`.
- `inFlight = task` happens **synchronously** between awaits inside `summarize` — this is the load-bearing "no reentrancy window" invariant.
- Two catch clauses in `callRespond` matching the spec's mapping table.

- [ ] **Step 5: Build and run**

```bash
cd /tmp/memsearch-spikes/spike-0c
swift run
```

Expected: `ALL PASS`. Total wall-clock will be a few minutes — Apple Intelligence inference is not free.

If any `FAIL:` line prints, this is the most consequential spike failure of Phase 0. Jump to Step 7 immediately — do not soldier on without applying the pivot.

- [ ] **Step 6: Capture metrics**

For the result note:
- macOS version, hardware (chip, RAM).
- Total calls / succeeded / ConcurrentRequests errors / other errors.
- Wall-clock for the full run.
- Whether intervals were strictly non-overlapping (paste the prev/curr from the FAIL line if it triggered).

- [ ] **Step 7: Write the result note**

Create `docs/superpowers/spikes/2026-05-20-spike-0c-foundationmodels.md`:

```markdown
# Spike 0c — FoundationModels single-flight stress test

**Date:** 2026-05-20
**Phase:** 0
**Risk it covers:** Spec's chained-Task `inFlight` single-flight pattern under concurrent stress; LanguageModelSession constraint discovery.

## Environment

- macOS: <version>
- Hardware: <chip + RAM>
- Apple Intelligence enabled: yes
- Swift: <version>
- macOS SDK: <version>

## Result

**Outcome:** PASS / FAIL

- Total calls: 1000 (10 × 100)
- Succeeded: <n>
- `concurrentRequests` errors: <n> (PASS criterion: 0)
- Other errors: <n>
- Wall clock: <duration>

### Done criterion (a) — zero concurrentRequests

PASS / FAIL.

### Done criterion (b) — FIFO + non-overlapping intervals

PASS / FAIL.

If FAIL: document which invariant broke (overlapping intervals, FIFO violation, or both) and the worst offender's `(start, end)` pair.

## Spec implications

- <"Single-flight pattern verified — design holds." OR list pivots applied to design spec.>

If failure: link to the commit that revised the single-flight pattern; describe the new primitive used (e.g., serial executor, semaphore, AsyncStream-based queue).

## Notes

<Anything surprising about LanguageModelSession behavior; constraints discovered; deferred items.>
```

- [ ] **Step 8: If a failure mode hit, revise pattern and patch spec**

This is the high-stakes branch. Per the phasing doc:
1. Consult Apple sample code (`developer.apple.com/documentation/foundationmodels`).
2. Revise the single-flight pattern. Candidates:
   - A serial executor (`UnownedSerialExecutor`) for the actor.
   - An explicit `AsyncStream`-based work queue.
   - A `withCheckedContinuation` chain.
3. Update the design spec's `FoundationModelsSummarizer` definition.
4. Re-run Spike 0c with the new pattern; confirm `ALL PASS`.
5. Commit the spec patch with `docs: spec patch — Spike 0c single-flight revision`.

Phase 6 will inherit whatever pattern lands; Phase 0 must close with `ALL PASS` against the current spec.

- [ ] **Step 9: Commit the result note**

```bash
git add docs/superpowers/spikes/2026-05-20-spike-0c-foundationmodels.md
git commit -m "docs: spike 0c result — FoundationModels single-flight stress"
```

---

## Task 6: Pinned Python ground-truth fixture

**Goal:** Pin a reproducible Python `memsearch` baseline (corpus + queries + top-5 + manifest + SHA) that Phase 1 (cross-check at criterion 6), Phase 3 (SwiftData success criterion), and Phase 5 (per-embedder success criterion) all reference. Without this fixture, those measurements are irreproducible.

**Files:**
- Create: `tests/fixtures/python-baseline/corpus/` (~80–100 .md files)
- Create: `tests/fixtures/python-baseline/queries.json`
- Create: `tests/fixtures/python-baseline/python-top5.json`
- Create: `tests/fixtures/python-baseline/python-top5.json.sha256`
- Create: `tests/fixtures/python-baseline/manifest.json`

- [ ] **Step 1: Copy the repo's existing markdown into the fixture corpus**

Source: this repo's own markdown (~38 files: project root README/AGENT/MEMORY/CONTRIBUTING/CLAUDE plus everything under `docs/` and `plugins/*/README.md`). The phasing doc says "~100" but its `~` gives latitude; ~38 files × 5–10 chunks per file gives 200–400 chunks, plenty for meaningful top-5 cross-checks. The manifest pins the actual count.

```bash
cd /Users/ronny/rdev/memsearch
# Pull every project markdown that isn't an auto-generated docs directory.
# Path-as-filename flatten so corpus/ is one level deep — `cp --parents` is GNU-only.
find docs README.md AGENT.md MEMORY.md CONTRIBUTING.md CLAUDE.md plugins -name '*.md' \
    -not -path '*/superpowers/*' -not -path '*/site/*' -not -path '*/node_modules/*' \
    | while IFS= read -r f; do
        dst="tests/fixtures/python-baseline/corpus/$(echo "$f" | tr / __)"
        cp "$f" "$dst"
      done
```

```bash
ls tests/fixtures/python-baseline/corpus/ | wc -l
```

Record the final count for the manifest.

- [ ] **Step 2: Write `queries.json`**

Choose 5–10 queries that exercise the corpus's vocabulary. Mix specific (proper nouns) and general (concepts).

Create `tests/fixtures/python-baseline/queries.json`:

```json
{
  "queries": [
    "How does the chunker split markdown by headings?",
    "What is hybrid search and how does RRF combine retrievers?",
    "Configure ONNX bge-m3 as the default embedder",
    "Claude Code plugin memory recall skill",
    "FTS5 BM25 with sqlite-vec",
    "Composite chunk ID format",
    "Watchdog file watcher debounce",
    "compact command summarization"
  ],
  "topK": 5
}
```

- [ ] **Step 3: Index the fixture corpus with Python `memsearch`**

The Python `memsearch` is already installed in this repo (CLAUDE.md describes the toolchain). Use the **ONNX bge-m3** provider for reproducibility — no API key needed, deterministic output.

```bash
cd /Users/ronny/rdev/memsearch
uv sync --extra onnx
# Index against a temporary collection so we don't pollute the user's real index.
COLL=memsearch_swift_baseline
uv run memsearch index \
    --paths tests/fixtures/python-baseline/corpus \
    --collection "$COLL" \
    --provider onnx \
    --model bge-m3 \
    --force
```

Expected: `index` reports the number of chunks written and the collection name. If `index` errors, debug before continuing — the fixture is load-bearing.

- [ ] **Step 4: Run each query and capture top-5 to `python-top5.json`**

Build the JSON with Python rather than shell concatenation so trailing-comma / quoting issues don't sneak in. Create a one-shot script:

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
         "--collection", "memsearch_swift_baseline",
         "--provider", "onnx",
         "--model", "bge-m3",
         "--json"],
        capture_output=True, text=True, check=True
    )
    hits = json.loads(proc.stdout)
    # Strip volatile fields (timing, internal state) and keep ID + score + source identity.
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
```

Verify the file:

```bash
jq '.results | length' tests/fixtures/python-baseline/python-top5.json
```

Expected: the same count as `queries.json`'s `queries` array.

- [ ] **Step 5: Compute SHA-256 of `python-top5.json`**

```bash
cd tests/fixtures/python-baseline
shasum -a 256 python-top5.json | awk '{print $1}' > python-top5.json.sha256
cat python-top5.json.sha256
```

This file gets committed alongside `python-top5.json`. Future re-runs hash the JSON and compare; mismatch = drift.

- [ ] **Step 6: Capture pip freeze for the manifest**

```bash
uv pip freeze > /tmp/pip-freeze-snapshot.txt
```

Keep this open — Step 7 references it.

- [ ] **Step 7: Write `manifest.json`**

Create `tests/fixtures/python-baseline/manifest.json`:

```json
{
  "fixture_version": 1,
  "date": "2026-05-20",
  "python": {
    "version": "<output of `python --version` minus 'Python '>",
    "memsearch_version": "<output of `uv run memsearch --version` if exposed; else commit SHA of repo HEAD>",
    "pip_freeze_path": "manifest.json holds a pinned snapshot in `python.pip_freeze` below"
  },
  "embedder": {
    "provider": "onnx",
    "model": "bge-m3",
    "dimension": 1024,
    "batch_size": "<exact `--batch-size` flag, or `default` if unspecified>",
    "extra_kwargs": {}
  },
  "chunker": {
    "max_chunk_size": 1500,
    "overlap_lines": 2,
    "heading_split": true,
    "dedup_key": "content_hash",
    "comment": "Phase 1's Swift `Chunker` defaults must match these byte-for-byte for the fixture corpus, or the cross-check measures chunker drift instead of embedder drift."
  },
  "corpus": {
    "path": "corpus/",
    "file_count": "<output of `ls corpus/ | wc -l`>"
  },
  "queries": {
    "path": "queries.json",
    "topK": 5,
    "count": "<count of queries[].queries>"
  },
  "results": {
    "path": "python-top5.json",
    "sha256_path": "python-top5.json.sha256"
  },
  "python_pip_freeze": [
    "<paste each line of /tmp/pip-freeze-snapshot.txt as a string element>"
  ]
}
```

Substitute the placeholder strings with real values. The `python_pip_freeze` array is the authoritative environment pin — paste every line.

Validate the JSON parses:

```bash
jq . tests/fixtures/python-baseline/manifest.json > /dev/null
```

If `jq` errors, fix the JSON before committing.

- [ ] **Step 8: Commit the fixture**

```bash
git add tests/fixtures/python-baseline/
git commit -m "test: add Python ground-truth fixture for Swift cross-check (Phase 0)"
```

---

## Task 7: Spikes index + Phase 0 notes

**Goal:** Provide a single-page index of all three spike outcomes and the fixture, plus a `phase-0-notes.md` documenting any spec deltas applied during Phase 0 and any items deferred to later phases.

**Files:**
- Create: `docs/superpowers/spikes/index.md`
- Create: `docs/superpowers/phases/phase-0-notes.md`

- [ ] **Step 1: Write `docs/superpowers/spikes/index.md`**

```markdown
# Phase 0 Spikes — Index

| Spike | Topic | Outcome | Result note |
| ----- | ----- | ------- | ----------- |
| 0a    | GRDB 7.x + sqlite-vec + reader concurrency | <PASS\|PIVOT> | [link](2026-05-20-spike-0a-sqlite-vec.md) |
| 0b    | swift-transformers Core ML + actor init shape | <PASS\|PIVOT> | [link](2026-05-20-spike-0b-coreml-bge.md) |
| 0c    | FoundationModels single-flight stress | <PASS\|PIVOT> | [link](2026-05-20-spike-0c-foundationmodels.md) |

## Pinned Python ground-truth fixture

Location: `tests/fixtures/python-baseline/`
SHA pin: see `python-top5.json.sha256`.
Referenced by: Phase 1 (criterion 6), Phase 3 (success criterion), Phase 5 (success criterion).

## Spec patches applied during Phase 0

<List each commit applied during Phase 0 — both the "close gaps before spikes" commit from Task 2 and any pivots from individual spikes. Format: `<commit short SHA> — <message>`. If none, write "None — design held against all three spikes".>

## Phase 0 exit verdict

<PASS — all three spikes ALL PASS, fixture pinned, spec coherent.>
<PIVOT — list which phase plans (1, 2, 3, 5, 6) need re-baselining and why.>
```

- [ ] **Step 2: Write `docs/superpowers/phases/phase-0-notes.md`**

```markdown
# Phase 0 — Notes

**Period:** 2026-05-20 → <end date>
**Status:** <complete | blocked>

## Surprises

<Anything that didn't match expectations going in. Examples: sqlite-vec extension loaded fine but vec0 KNN required an unexpected schema variant; Apple Intelligence on the test Mac took 4× longer than expected per call; etc. If nothing surprising, write "None.">

## Spec deltas applied

<Each commit hash + short description. Format: `<sha> — <reason>`. Same as the spikes/index.md "Spec patches" section but with prose detail.>

## Items deferred to later phases

<Anything noticed during spikes that's worth recording for later. Examples: "Spike 0a noticed sqlite-vec returns Float32 distances even on Float64 inputs — Phase 1 cosine math should use Float32"; "Spike 0c noticed Apple Intelligence response time scales with prompt length — consider input truncation in Phase 6.">

## Phase 1 entry checklist

- [ ] Spec is coherent (every Task 2 grep passes after any pivots).
- [ ] If Spike 0a hit failure mode (c), Phase 1's plan is regenerated against the new (no-vec0) `MemSearchSQLite` deliverables.
- [ ] If Spike 0b hit the actor-shape failure, every CoreMLEmbedder/ONNXEmbedder construction site in the spec uses the static-factory pattern.
- [ ] Pinned Python fixture exists and is reproducible from the manifest.
```

- [ ] **Step 3: Commit Phase 0 wrap-up**

```bash
git add docs/superpowers/spikes/index.md docs/superpowers/phases/phase-0-notes.md
git commit -m "docs: phase 0 wrap — spikes index + phase notes"
```

---

## Task 8: Phase 0 exit verification

**Goal:** Mechanical pass to confirm every Phase 0 deliverable is in place and the design spec is coherent. No new content — purely verification.

- [ ] **Step 1: Verify all three spike result notes exist**

```bash
ls docs/superpowers/spikes/2026-05-20-spike-0a-sqlite-vec.md \
   docs/superpowers/spikes/2026-05-20-spike-0b-coreml-bge.md \
   docs/superpowers/spikes/2026-05-20-spike-0c-foundationmodels.md \
   docs/superpowers/spikes/index.md
```

Expected: all four paths print, no errors.

- [ ] **Step 2: Verify the fixture is committed**

```bash
ls tests/fixtures/python-baseline/manifest.json \
   tests/fixtures/python-baseline/queries.json \
   tests/fixtures/python-baseline/python-top5.json \
   tests/fixtures/python-baseline/python-top5.json.sha256
ls tests/fixtures/python-baseline/corpus/ | wc -l
git ls-files tests/fixtures/python-baseline/ | head -5
```

Expected: every file exists, corpus has > 0 files, `git ls-files` returns the fixture (i.e., it's committed, not untracked).

- [ ] **Step 3: Verify the SHA-256 still matches**

```bash
cd tests/fixtures/python-baseline
expected=$(cat python-top5.json.sha256)
actual=$(shasum -a 256 python-top5.json | awk '{print $1}')
[ "$expected" = "$actual" ] && echo "SHA OK" || echo "DRIFT: $expected vs $actual"
```

Expected: `SHA OK`. Drift means `python-top5.json` was modified after `python-top5.json.sha256` was computed — re-run Task 6 Step 5.

- [ ] **Step 4: Re-run Task 2 Step 11's spec greps**

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

Every line non-zero; the last line exactly `2`.

- [ ] **Step 5: Verify the phase-0 notes capture every spec patch commit**

```bash
git log --oneline --since="2026-05-20" -- docs/superpowers/specs/2026-05-20-swift-rewrite-design.md
```

Cross-check: every commit listed is referenced in `docs/superpowers/phases/phase-0-notes.md` and `docs/superpowers/spikes/index.md`. If any commit isn't named, edit the notes to mention it and recommit (`docs: phase 0 wrap — round out spec deltas list`).

- [ ] **Step 6: Verify scratch dirs are NOT in git**

```bash
git ls-files | grep -F memsearch-spikes && echo "FAIL: scratch tracked" || echo "OK: scratch untracked"
git status --short | grep -F memsearch-spikes && echo "FAIL: scratch in working tree" || echo "OK: working tree clean"
```

Expected: both lines print `OK`. If `FAIL` on either, the spike code accidentally landed in the repo — `git rm` and recommit, or delete from working tree.

- [ ] **Step 7: Final phase verdict**

If every previous step passed:
- Phase 0 is **DONE**. Phase 1 plan can now be written against the (now-coherent) design spec.

If a step failed:
- Stop. Fix the failing step. Re-run from Step 1.

No commit on this task — it's a verification pass.

---

## Self-review notes

**Spec coverage** — every Phase 0 deliverable from the phasing doc has a task:
- 7 spec patches → Task 2 (Steps 1–7) + 2 derived inconsistencies in Steps 8–9.
- Spike 0a → Task 3.
- Spike 0b → Task 4.
- Spike 0c → Task 5 (with explicit hard-required precondition).
- Pinned Python fixture (corpus + queries + top-5 + SHA + manifest) → Task 6.
- `spikes/index.md` summary → Task 7.
- `phase-0-notes.md` per cross-cutting rituals → Task 7.
- Exit criterion verification → Task 8.

**Placeholder scan** — no TBD/TODO; every step has concrete commands/code or a clear "if missing, edit X" branch. The model-specific helpers in Spike 0b (`makeMLInput`, `extractDimension`) are explicitly flagged as implementer-fills-in for whichever model lands.

**Type consistency** — `MemSearchError.unimplemented(String)`, `LLMError.singleFlightViolation(any Error & Sendable)`, and `MockEmbeddingProvider.latencyPerBatch: Duration?` are spelled identically every place they appear. Spike 0c's `StressActor` matches the design spec's `FoundationModelsSummarizer` shape (chained-Task, `[weak self]`, two catch clauses, synchronous `inFlight = task` between awaits).

**Skill alignment** — TaskGroup over Task-loop, ContinuousClock for timing, structured concurrency throughout, `nonisolated let` actor-init pattern in Spike 0b, no `@unchecked Sendable` or `nonisolated(unsafe)` anywhere.
