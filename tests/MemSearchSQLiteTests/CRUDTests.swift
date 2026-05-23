import Foundation
import Testing
import GRDB
import MemSearch
@testable import MemSearchSQLite

@Suite("SQLite CRUD")
struct CRUDTests {

    // MARK: - Helpers

    /// Per-test directory. Captures WAL sidecars cleanly — tracked by
    /// Task 19's iteration-2 review (single-file pattern leaks `*.db-wal`).
    private static func makeTempDir(prefix: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeChunk(
        id: String,
        source: String = "/tmp/x.md",
        content: String = "alpha"
    ) -> Chunk {
        Chunk(
            id: ChunkID(id),
            source: URL(fileURLWithPath: source),
            heading: "h",
            headingLevel: 1,
            startLine: 1,
            endLine: 2,
            content: content,
            contentHash: ChunkID.contentHash(for: content)
        )
    }

    private static func makeEmbedding(_ floats: [Float], dim: Int) throws -> Embedding {
        try Embedding(values: floats, expectedDimension: dim)
    }

    // MARK: - Tests

    @Test("upsert inserts a record discoverable via indexedSources / chunkIDs(forSource:)")
    func upsertAndQuery() async throws {
        let dir = try Self.makeTempDir(prefix: "crud")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await SQLiteVectorStore(url: dir.appendingPathComponent("memsearch.db"), dimension: 4)

        let src = URL(fileURLWithPath: "/tmp/upsert.md")
        let chunk = Chunk(
            id: ChunkID("u1"),
            source: src,
            heading: "h",
            headingLevel: 1,
            startLine: 1,
            endLine: 2,
            content: "alpha",
            contentHash: ChunkID.contentHash(for: "alpha")
        )
        let emb = try Self.makeEmbedding([0.1, 0.2, 0.3, 0.4], dim: 4)
        let written = try await store.upsert([StoredChunk(chunk: chunk, embedding: emb)])
        #expect(written == 1)

        let sources = try await store.indexedSources()
        #expect(sources == Set([src]))

        let ids = try await store.chunkIDs(forSource: src)
        #expect(ids == Set([ChunkID("u1")]))
    }

    @Test("delete(ids:) removes selected chunk while siblings remain")
    func deleteByIDs() async throws {
        let dir = try Self.makeTempDir(prefix: "crud")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await SQLiteVectorStore(url: dir.appendingPathComponent("memsearch.db"), dimension: 4)

        let src = URL(fileURLWithPath: "/tmp/two.md")
        let c1 = Self.makeChunk(id: "a", source: src.path, content: "alpha")
        let c2 = Self.makeChunk(id: "b", source: src.path, content: "beta")
        let e1 = try Self.makeEmbedding([0.1, 0.2, 0.3, 0.4], dim: 4)
        let e2 = try Self.makeEmbedding([0.5, 0.6, 0.7, 0.8], dim: 4)
        let n = try await store.upsert([
            StoredChunk(chunk: c1, embedding: e1),
            StoredChunk(chunk: c2, embedding: e2),
        ])
        #expect(n == 2)

        let deleted = try await store.delete(ids: [ChunkID("a")])
        #expect(deleted == 1)

        let sources = try await store.indexedSources()
        #expect(sources == Set([src]))

        let ids = try await store.chunkIDs(forSource: src)
        #expect(ids == Set([ChunkID("b")]))
    }

    @Test("delete(source:) removes every row for that source")
    func deleteBySource() async throws {
        let dir = try Self.makeTempDir(prefix: "crud")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await SQLiteVectorStore(url: dir.appendingPathComponent("memsearch.db"), dimension: 4)

        let src = URL(fileURLWithPath: "/tmp/del.md")
        let c1 = Self.makeChunk(id: "x", source: src.path, content: "x1")
        let c2 = Self.makeChunk(id: "y", source: src.path, content: "y1")
        let e = try Self.makeEmbedding([0.1, 0.2, 0.3, 0.4], dim: 4)
        _ = try await store.upsert([
            StoredChunk(chunk: c1, embedding: e),
            StoredChunk(chunk: c2, embedding: e),
        ])

        let removed = try await store.delete(source: src)
        #expect(removed == 2)

        let sources = try await store.indexedSources()
        #expect(sources.isEmpty)

        let ids = try await store.chunkIDs(forSource: src)
        #expect(ids.isEmpty)
    }

    @Test("dimensionMismatch is thrown before any state changes")
    func dimensionMismatchThrows() async throws {
        let dir = try Self.makeTempDir(prefix: "crud")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await SQLiteVectorStore(url: dir.appendingPathComponent("memsearch.db"), dimension: 8)

        let chunk = Self.makeChunk(id: "z")
        let badEmb = try Self.makeEmbedding([0.1, 0.2, 0.3], dim: 3)

        await #expect(throws: VectorStoreError.self) {
            _ = try await store.upsert([StoredChunk(chunk: chunk, embedding: badEmb)])
        }

        // No state change: indexedSources stays empty.
        let sources = try await store.indexedSources()
        #expect(sources.isEmpty)
    }

    @Test("upsert overwriting an existing chunk_id removes the orphan vec0 row")
    func upsertOverwriteCleansOrphanVec0() async throws {
        let dir = try Self.makeTempDir(prefix: "crud")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await SQLiteVectorStore(url: dir.appendingPathComponent("memsearch.db"), dimension: 4)

        let src = URL(fileURLWithPath: "/tmp/orphan.md")

        // First upsert.
        let chunkV1 = Chunk(
            id: ChunkID("same"),
            source: src,
            heading: "h",
            headingLevel: 1,
            startLine: 1,
            endLine: 2,
            content: "v1",
            contentHash: ChunkID.contentHash(for: "v1")
        )
        let e1 = try Self.makeEmbedding([0.1, 0.2, 0.3, 0.4], dim: 4)
        _ = try await store.upsert([StoredChunk(chunk: chunkV1, embedding: e1)])

        // Second upsert with the SAME chunk_id but a different embedding.
        // INSERT OR REPLACE on chunks_meta DELETEs the old row (firing chunks_meta_ad_vec)
        // and INSERTs a new row with a fresh rowid. Then the chunks_vec write goes
        // to the new rowid. The trigger should leave exactly one row in chunks_vec.
        let chunkV2 = Chunk(
            id: ChunkID("same"),
            source: src,
            heading: "h",
            headingLevel: 1,
            startLine: 1,
            endLine: 2,
            content: "v2",
            contentHash: ChunkID.contentHash(for: "v2")
        )
        let e2 = try Self.makeEmbedding([0.9, 0.8, 0.7, 0.6], dim: 4)
        _ = try await store.upsert([StoredChunk(chunk: chunkV2, embedding: e2)])

        let vecCount: Int = try await store.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunks_vec")!
        }
        #expect(vecCount == 1, "orphan-prevention trigger must keep chunks_vec at 1 row after overwrite")

        let metaCount: Int = try await store.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunks_meta")!
        }
        #expect(metaCount == 1, "chunks_meta should also have exactly one row")
    }
}
