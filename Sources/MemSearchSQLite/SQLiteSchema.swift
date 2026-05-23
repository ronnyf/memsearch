import Foundation
import GRDB
import MemSearch

enum SQLiteSchema {
    static func migrate(pool: DatabasePool, dimension: Int) throws {
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
            try db.execute(sql: "CREATE VIRTUAL TABLE chunks_vec USING vec0(embedding float[\(dimension)] distance_metric=cosine);")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE chunks_fts USING fts5(
                    content, content='chunks_meta', tokenize='porter unicode61'
                );
            """)
            try db.execute(sql: "CREATE TRIGGER chunks_meta_ai AFTER INSERT ON chunks_meta BEGIN INSERT INTO chunks_fts(rowid,content) VALUES (new.rowid,new.content); END;")
            try db.execute(sql: "CREATE TRIGGER chunks_meta_ad AFTER DELETE ON chunks_meta BEGIN INSERT INTO chunks_fts(chunks_fts,rowid,content) VALUES ('delete',old.rowid,old.content); END;")
            try db.execute(sql: "CREATE TRIGGER chunks_meta_au AFTER UPDATE ON chunks_meta BEGIN INSERT INTO chunks_fts(chunks_fts,rowid,content) VALUES ('delete',old.rowid,old.content); INSERT INTO chunks_fts(rowid,content) VALUES (new.rowid,new.content); END;")
            try db.execute(sql: """
                CREATE TRIGGER chunks_meta_ad_vec AFTER DELETE ON chunks_meta BEGIN
                    DELETE FROM chunks_vec WHERE rowid = old.rowid;
                END;
            """)
        }
        do { try migrator.migrate(pool) }
        catch { throw VectorStoreError.connectionFailed(error) }
    }
}
