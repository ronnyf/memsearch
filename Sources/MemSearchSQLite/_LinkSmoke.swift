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
