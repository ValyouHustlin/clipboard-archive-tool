import Foundation
import SQLite3

/// Runs a read-only query with the same literal matcher as This Window.
/// Filtering happens before LIMIT and before copying result bodies out of
/// SQLite; no query or clipboard text is placed in process arguments.
enum ClipboardSQLiteSearch {
    private final class Query {
        let terms: [String]
        init(_ terms: [String]) { self.terms = terms }
    }

    static func rows(indexURL: URL, sql: String, terms: [String]) throws -> [[String: Any]] {
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(indexURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard opened == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw ClipboardDerivedIndexError.sqliteFailed(opened)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1000)
        let query = Query(terms)
        // Query stays alive until every step is finished, including callbacks.
        return try withExtendedLifetime(query) {
            let registered = sqlite3_create_function_v2(database, "clipboard_matches", 1,
                SQLITE_UTF8 | SQLITE_DETERMINISTIC, Unmanaged.passUnretained(query).toOpaque(),
                { context, _, arguments in
                    guard let context, let argument = arguments?[0],
                          let pointer = sqlite3_value_text(argument),
                          let userData = sqlite3_user_data(context) else {
                        sqlite3_result_int(context, 0)
                        return
                    }
                    let count = Int(sqlite3_value_bytes(argument))
                    let text = String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self)
                    let query = Unmanaged<Query>.fromOpaque(userData).takeUnretainedValue()
                    sqlite3_result_int(context, ClipboardSearchText.matches(text, terms: query.terms) ? 1 : 0)
                }, nil, nil, nil)
            guard registered == SQLITE_OK else { throw ClipboardDerivedIndexError.sqliteFailed(registered) }
            // Bound selected text inside SQLite, before sorting/accumulating
            // rows. A page of large bodies must not become a page-sized copy
            // of the archive in the app's result array.
            let snippetRegistered = sqlite3_create_function_v2(database, "clipboard_snippet", 1,
                SQLITE_UTF8 | SQLITE_DETERMINISTIC, Unmanaged.passUnretained(query).toOpaque(),
                { context, _, arguments in
                    guard let context, let argument = arguments?[0],
                          let pointer = sqlite3_value_text(argument),
                          let userData = sqlite3_user_data(context) else {
                        sqlite3_result_null(context)
                        return
                    }
                    let text = String(decoding: UnsafeBufferPointer(start: pointer,
                        count: Int(sqlite3_value_bytes(argument))), as: UTF8.self)
                    let query = Unmanaged<Query>.fromOpaque(userData).takeUnretainedValue()
                    let snippet = ClipboardSearchText.snippet(text, terms: query.terms)
                    snippet.withCString { pointer in
                        sqlite3_result_text(context, pointer, Int32(snippet.utf8.count),
                            unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    }
                }, nil, nil, nil)
            guard snippetRegistered == SQLITE_OK else {
                throw ClipboardDerivedIndexError.sqliteFailed(snippetRegistered)
            }
            var statement: OpaquePointer?
            var tail: UnsafePointer<CChar>?
            let prepared = sqlite3_prepare_v2(database, sql, -1, &statement, &tail)
            guard prepared == SQLITE_OK, let statement else {
                throw ClipboardDerivedIndexError.sqliteFailed(prepared)
            }
            // Only the FIRST statement is prepared, and silently running one
            // statement of a script is the kind of wrong that reads as a
            // correct empty result. Anything left over is refused.
            if let tail,
               !String(cString: tail).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sqlite3_finalize(statement)
                throw ClipboardDerivedIndexError.sqliteFailed(SQLITE_MISUSE)
            }
            defer { sqlite3_finalize(statement) }
            var rows: [[String: Any]] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { return rows }
                guard step == SQLITE_ROW else { throw ClipboardDerivedIndexError.sqliteFailed(step) }
                var row: [String: Any] = [:]
                for column in 0..<sqlite3_column_count(statement) {
                    let name = String(cString: sqlite3_column_name(statement, column))
                    if sqlite3_column_type(statement, column) == SQLITE_INTEGER {
                        row[name] = Int(sqlite3_column_int64(statement, column))
                    } else if let pointer = sqlite3_column_text(statement, column) {
                        row[name] = String(decoding: UnsafeBufferPointer(start: pointer,
                            count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
                    }
                }
                rows.append(row)
            }
        }
    }
}
