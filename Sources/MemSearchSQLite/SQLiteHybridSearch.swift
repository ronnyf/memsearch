import Foundation
import GRDB
import MemSearch

extension SQLiteVectorStore {

    /// Hybrid retrieval: vec0 cosine KNN + FTS5 BM25, fused by RRF.
    ///
    /// **Single-tx invariant.** Both rankings AND the final metadata fetch run
    /// inside ONE `pool.read { db in ... }` closure, with NO `await` inside.
    /// Splitting these into two reads would let a concurrent writer change the
    /// world between dense and BM25 queries, producing inconsistent fused
    /// rankings. Spec line 437. Do not refactor to extract async helpers.
    ///
    /// **`distance_metric=cosine` (Task 19).** vec0 returns cosine distance in
    /// [0, 2]; lower is better, so `ORDER BY distance ASC` puts the closest
    /// vector first — the order RRF.fuse expects (best-to-worst).
    ///
    /// **FTS5 `bm25(...)` sign.** Returns negative scores where more-negative
    /// means a better match. `ORDER BY score ASC` therefore yields the best
    /// matches first. The raw scores are forwarded into `bm25Score` for the
    /// caller; RRF only consumes the ranking order, not the score values.
    public func hybridSearch(_ q: HybridQuery) async throws -> [SearchHit] {
        guard q.queryEmbedding.dimension == dimension else {
            throw VectorStoreError.dimensionMismatch(
                expected: dimension,
                got: q.queryEmbedding.dimension
            )
        }
        do {
            return try await pool.read { db in
                // Over-fetch each retriever to give RRF room to fuse — `topK * 5`
                // tracks the Python sibling's heuristic, with a 50-row floor for
                // small-topK queries.
                let candidates = max(q.topK * 5, 50)
                let qBlob = embeddingBlob(q.queryEmbedding.values)

                // Dense KNN. vec0's `xBestIndex` only recognises the KNN
                // query plan when MATCH + ORDER BY distance + LIMIT all sit
                // on the vec0 virtual table directly. JOINing chunks_meta in
                // the same SELECT moves the LIMIT outside vec0's reach and
                // produces "A LIMIT or 'k = ?' constraint is required on
                // vec0 knn queries". Wrap the vec0 read in a subquery and
                // JOIN to chunks_meta over the result.
                let denseRows = try Row.fetchAll(db, sql: """
                    SELECT chunks_meta.chunk_id AS cid, v.dist AS dist
                    FROM (
                        SELECT rowid, distance AS dist
                        FROM chunks_vec
                        WHERE embedding MATCH ?
                        ORDER BY distance
                        LIMIT ?
                    ) AS v
                    JOIN chunks_meta ON chunks_meta.rowid = v.rowid
                    ORDER BY v.dist
                """, arguments: [qBlob, candidates])
                let denseRanking: [(ChunkID, Float)] = denseRows.map {
                    (ChunkID($0["cid"] as String), Float($0["dist"] as Double))
                }

                // BM25 lexical. `bm25(chunks_fts)` returns negative scores;
                // ascending order = best-match first.
                let ftsRows = try Row.fetchAll(db, sql: """
                    SELECT chunks_meta.chunk_id AS cid, bm25(chunks_fts) AS score
                    FROM chunks_fts
                    JOIN chunks_meta ON chunks_meta.rowid = chunks_fts.rowid
                    WHERE chunks_fts MATCH ?
                    ORDER BY score
                    LIMIT ?
                """, arguments: [q.queryText, candidates])
                let ftsRanking: [(ChunkID, Float)] = ftsRows.map {
                    (ChunkID($0["cid"] as String), Float($0["score"] as Double))
                }

                // RRF.fuse consumes ID rankings (best-to-worst) and returns
                // normalized [0, 1] fused scores. We retain raw dense + BM25
                // scores per ID for the SearchHit payload.
                let fused = RRF.fuse(
                    [denseRanking.map(\.0), ftsRanking.map(\.0)],
                    k: q.rrfK,
                    topK: q.topK
                )
                let denseScores = Dictionary(uniqueKeysWithValues: denseRanking)
                let bm25Scores = Dictionary(uniqueKeysWithValues: ftsRanking)

                let ids = fused.map(\.0.rawValue)
                guard !ids.isEmpty else { return [] }

                // Single batched IN(...) fetch keeps the metadata read inside
                // the same snapshot as the two ranking queries above.
                let placeholders = Array(repeating: "?", count: ids.count)
                    .joined(separator: ",")
                let metaRows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM chunks_meta WHERE chunk_id IN (\(placeholders))",
                    arguments: StatementArguments(ids)
                )
                let chunksByID = Dictionary(uniqueKeysWithValues: metaRows.map {
                    (ChunkID($0["chunk_id"] as String), Chunk.make(fromMetaRow: $0))
                })

                return fused.compactMap { id, fusedScore in
                    guard let chunk = chunksByID[id] else { return nil }
                    return SearchHit(
                        chunk: chunk,
                        score: fusedScore,
                        denseScore: denseScores[id],
                        bm25Score: bm25Scores[id]
                    )
                }
            }
        } catch let e as VectorStoreError {
            throw e
        } catch {
            throw VectorStoreError.backendError(error)
        }
    }
}
