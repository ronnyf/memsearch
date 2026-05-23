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
