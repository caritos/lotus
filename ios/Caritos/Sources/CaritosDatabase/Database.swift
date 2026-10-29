/// The one owner of an app's SQLite connection. Every call runs on this actor, so writes from
/// concurrent tasks are serialized and a transaction (synchronous, no suspension inside) can never
/// interleave with another call. Features take a `Database`; none opens its own connection.
public actor Database {
    private let connection: SQLiteConnection

    /// Opens (creating if needed) the database file at `path`, in WAL mode with foreign keys on.
    public init(path: String) throws {
        connection = try SQLiteConnection(path: path)
    }

    /// A private, empty database that lives as long as this instance (tests, previews).
    public static func inMemory() throws -> Database {
        try Database(path: ":memory:")
    }

    /// Runs `sql` with `bindings` and returns its rows. See `Transaction.execute` for scripts.
    @discardableResult
    public func execute(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> [SQLiteRow] {
        try connection.execute(sql, bindings)
    }

    /// Runs `body` inside one transaction: committed when it returns, rolled back when it throws
    /// (or when the commit itself fails). The body is synchronous, so nothing else runs on this
    /// database until it finishes.
    @discardableResult
    public func transaction<T: Sendable>(_ body: (Transaction) throws -> T) throws -> T {
        try connection.begin()
        let result: T
        do {
            result = try body(Transaction(connection: connection))
            try connection.commit()
        } catch {
            // The original error is what the caller needs; a failed rollback here means SQLite already
            // rolled the transaction back itself.
            try? connection.rollback()
            throw error
        }
        return result
    }
}

/// The handle a `Database.transaction` body uses to run statements inside the transaction.
public struct Transaction {
    let connection: SQLiteConnection

    /// Runs `sql` with `bindings` inside the transaction. `sql` may be a script of several statements
    /// when no bindings are given; they run in order and stop at the first failure.
    @discardableResult
    public func execute(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> [SQLiteRow] {
        try connection.execute(sql, bindings)
    }
}
