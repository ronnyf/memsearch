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
                        } catch let cancel as CancellationError {
                            // Re-throw the original instance so the outer arm
                            // finishes the stream with the same value (cleaner
                            // than allocating a fresh `CancellationError()`).
                            throw cancel
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
                } catch let cancel as CancellationError {
                    continuation.finish(throwing: cancel)
                } catch {
                    continuation.finish(throwing: MemSearchEngineErrors.lift(error))
                }
            }
            continuation.onTermination = { reason in
                task.cancel()
                // `AsyncThrowingStream.Iterator.next()` returns `nil` (graceful
                // end) when the *consumer's* task is cancelled — the for-loop
                // would silently exit and `task.value` would not throw. Bridge
                // consumer-cancellation onto the stream so the iteration
                // surfaces as `CancellationError`, satisfying spec line 949
                // ("Swift.CancellationError flows through public methods
                // unchanged"). Idempotent: a second `finish(throwing:)` is a
                // no-op if the producer task already finished the stream.
                if case .cancelled = reason {
                    continuation.finish(throwing: CancellationError())
                }
            }
        }
    }

    public func indexFile(_ url: URL) async throws -> Int {
        do {
            let event = try await indexOne(url: url, force: false, modelName: embedder.modelName)
            if case .indexed(_, let a, _) = event { return a }
            return 0
        } catch {
            // Route through `MemSearchEngineErrors.lift` for canonical
            // mapping — recognised sub-errors become `MemSearchError`
            // cases, `CancellationError` flows through unchanged, and a
            // future case added to `lift` (e.g. `LLMError`) is picked up
            // automatically. Truly unknown errors are wrapped with the URL
            // so callers know which file failed; rendered through
            // `LocalizedError` so SwiftUI alerts see a readable string,
            // not a raw `"\(error)"` type-name leak.
            //
            // Note: `indexFile` does NOT mirror `indexStream`'s per-URL
            // catch arm that yields `IndexFileError`-shaped events. The
            // event-stream contract surfaces typed sub-errors per file;
            // the single-throw `indexFile` contract surfaces a single
            // `MemSearchError` (or `CancellationError`).
            let lifted = MemSearchEngineErrors.lift(error)
            if lifted is CancellationError { throw lifted }
            if let m = lifted as? MemSearchError { throw m }
            let message = (lifted as? LocalizedError)?.errorDescription
                ?? (lifted as NSError).localizedDescription
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
