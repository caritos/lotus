import Foundation

public enum SQLiteError: Error, Equatable {
    /// The database could not be opened or configured.
    case open(String)
    /// The SQL could not be compiled; carries the full SQL that was passed in.
    case prepare(sql: String, message: String)
    /// A statement failed while running (constraint, I/O, transaction state).
    case step(String)
    /// The number of bindings does not match the statement's parameters.
    case bindCount(expected: Int, got: Int)
}

extension SQLiteError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .open(let message):
            return "SQLite open failed: \(message)"
        case .prepare(let sql, let message):
            return "SQLite prepare failed: \(message) (SQL: \(sql))"
        case .step(let message):
            return "SQLite step failed: \(message)"
        case .bindCount(let expected, let got):
            return "SQLite bind failed: the statement takes \(expected) values but \(got) were given"
        }
    }
}
