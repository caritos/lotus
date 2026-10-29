import Foundation
import SQLite3

/// SQLITE_TRANSIENT: SQLite copies bound text and blobs before the bind call returns.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A raw SQLite connection. Internal and not Sendable: only `Database` (an actor) owns one,
/// so every call on it is serialized.
final class SQLiteConnection {
    private var db: OpaquePointer?

    init(path: String) throws {
        // FULLMUTEX as a second line of defence: Apple's SQLite is built THREADSAFE=2, so without it
        // nothing inside SQLite serializes calls on a shared handle.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            // sqlite3_open_v2 returns a handle even on failure so the error can be read; close it.
            sqlite3_close_v2(db)
            db = nil
            throw SQLiteError.open(message)
        }
        do {
            try execute("PRAGMA journal_mode = WAL", [])
            try execute("PRAGMA synchronous = NORMAL", [])
            try execute("PRAGMA foreign_keys = ON", [])
            try execute("PRAGMA busy_timeout = 5000", [])
        } catch {
            sqlite3_close_v2(db)
            db = nil
            throw SQLiteError.open("configuring \(path): \(error.localizedDescription)")
        }
    }

    deinit {
        sqlite3_close_v2(db)
    }

    /// Runs `sql` and returns the rows it produced.
    ///
    /// `sql` may hold several statements (a migration script); they run in order and stop at the first
    /// failure, with no implicit transaction. Bindings are only accepted for a single statement, and their
    /// count must match its parameters exactly.
    @discardableResult
    func execute(_ sql: String, _ bindings: [SQLiteValue]) throws -> [SQLiteRow] {
        let bytes = Array(sql.utf8CString)
        return try bytes.withUnsafeBufferPointer { buffer -> [SQLiteRow] in
            guard let start = buffer.baseAddress else { return [] }
            var cursor: UnsafePointer<CChar> = start
            var rows: [SQLiteRow] = []
            var statementCount = 0
            while cursor.pointee != 0 {
                var statement: OpaquePointer?
                var tail: UnsafePointer<CChar>?
                guard sqlite3_prepare_v2(db, cursor, -1, &statement, &tail) == SQLITE_OK else {
                    let message = errorMessage
                    sqlite3_finalize(statement)
                    throw SQLiteError.prepare(sql: sql, message: message)
                }
                defer { sqlite3_finalize(statement) }
                guard let next = tail, next > cursor else { break }
                cursor = next
                // Only whitespace or a comment was left: nothing to run.
                guard let statement else { continue }
                statementCount += 1
                // Checked before anything is stepped, so a rejected call changes nothing.
                if !bindings.isEmpty && hasStatement(from: cursor) {
                    throw SQLiteError.prepare(sql: sql, message: "bindings are only accepted for a single statement")
                }
                try bind(bindings, to: statement)
                rows += try run(statement)
            }
            if statementCount == 0 && !bindings.isEmpty {
                throw SQLiteError.bindCount(expected: 0, got: bindings.count)
            }
            return rows
        }
    }

    /// True when the SQL from `cursor` on holds anything but whitespace, comments and semicolons.
    /// Only prepares (never steps); SQL that fails to prepare counts as a statement.
    private func hasStatement(from start: UnsafePointer<CChar>) -> Bool {
        var cursor = start
        while cursor.pointee != 0 {
            var statement: OpaquePointer?
            var tail: UnsafePointer<CChar>?
            let result = sqlite3_prepare_v2(db, cursor, -1, &statement, &tail)
            sqlite3_finalize(statement)
            guard result == SQLITE_OK else { return true }
            if statement != nil { return true }
            guard let next = tail, next > cursor else { return false }
            cursor = next
        }
        return false
    }

    func begin() throws { try execute("BEGIN IMMEDIATE", []) }
    func commit() throws { try execute("COMMIT", []) }
    func rollback() throws { try execute("ROLLBACK", []) }

    private var errorMessage: String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "no connection"
    }

    private func bind(_ bindings: [SQLiteValue], to statement: OpaquePointer) throws {
        let expected = Int(sqlite3_bind_parameter_count(statement))
        guard expected == bindings.count else {
            throw SQLiteError.bindCount(expected: expected, got: bindings.count)
        }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(statement, index)
            case .integer(let number):
                result = sqlite3_bind_int64(statement, index, number)
            case .real(let number):
                result = sqlite3_bind_double(statement, index, number)
            case .text(let text):
                // Explicit byte length (not NUL-terminated) so an embedded NUL survives. A zero-length
                // text needs a non-null pointer, or SQLite binds NULL instead of ''.
                let utf8 = Array(text.utf8)
                result = utf8.withUnsafeBufferPointer { raw in
                    raw.baseAddress.map { base in
                        base.withMemoryRebound(to: CChar.self, capacity: raw.count) {
                            sqlite3_bind_text(statement, index, $0, Int32(raw.count), sqliteTransient)
                        }
                    } ?? sqlite3_bind_text(statement, index, "", 0, sqliteTransient)
                }
            case .blob(let data):
                // A nil pointer would bind NULL, so an empty blob is a zero-length zeroblob.
                result = data.isEmpty
                    ? sqlite3_bind_zeroblob(statement, index, 0)
                    : data.withUnsafeBytes { raw in
                        sqlite3_bind_blob(statement, index, raw.baseAddress, Int32(raw.count), sqliteTransient)
                    }
            }
            guard result == SQLITE_OK else {
                throw SQLiteError.step("binding parameter \(index): \(errorMessage)")
            }
        }
    }

    private func run(_ statement: OpaquePointer) throws -> [SQLiteRow] {
        let columnCount = sqlite3_column_count(statement)
        let columns = (0..<columnCount).map { String(cString: sqlite3_column_name(statement, $0)) }
        var rows: [SQLiteRow] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let values = (0..<columnCount).map { value(statement, column: $0) }
                rows.append(SQLiteRow(columns: columns, values: values))
            case SQLITE_DONE:
                return rows
            default:
                throw SQLiteError.step(errorMessage)
            }
        }
    }

    private func value(_ statement: OpaquePointer, column: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_NULL:
            return .null
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, column))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { return .blob(Data()) }
            return .blob(Data(bytes: pointer, count: count))
        default:
            // Text: read by byte length, never as a C string, so an embedded NUL is kept.
            guard let pointer = sqlite3_column_text(statement, column) else { return .text("") }
            let count = Int(sqlite3_column_bytes(statement, column))
            return .text(String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self))
        }
    }
}
