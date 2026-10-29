import Foundation
import Testing
@testable import CaritosDatabase

@Suite("SQLiteConnection")
struct SQLiteConnectionTests {
    @Test("round-trips every SQLiteValue case through bindings and columns")
    func roundTripsEveryValue() throws {
        let connection = try SQLiteConnection(path: ":memory:")
        try connection.execute("CREATE TABLE t (i INTEGER, r REAL, s TEXT, b BLOB, z)", [])
        let blob = Data([0x00, 0xFF, 0x10, 0x00])
        try connection.execute(
            "INSERT INTO t (i, r, s, b, z) VALUES (?, ?, ?, ?, ?)",
            [.integer(Int64.max), .real(3.25), .text("hello"), .blob(blob), .null]
        )

        let rows = try connection.execute("SELECT i, r, s, b, z FROM t", [])

        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row["i"] == .integer(Int64.max))
        #expect(row["r"] == .real(3.25))
        #expect(row["s"] == .text("hello"))
        #expect(row["b"] == .blob(blob))
        #expect(row["z"] == .null)
        #expect(row["missing"] == nil)
        #expect(row.integer("i") == Int64.max)
        #expect(row.text("s") == "hello")
        #expect(row.text("i") == nil)
        #expect(row.integer("s") == nil)
    }

    @Test("empty text and empty blob stay empty, not NULL")
    func emptyValues() throws {
        let connection = try SQLiteConnection(path: ":memory:")
        try connection.execute("CREATE TABLE t (s TEXT, b BLOB)", [])
        try connection.execute("INSERT INTO t VALUES (?, ?)", [.text(""), .blob(Data())])

        let row = try #require(try connection.execute("SELECT s, b, typeof(s) AS ts, typeof(b) AS tb FROM t", []).first)

        #expect(row["s"] == .text(""))
        #expect(row["b"] == .blob(Data()))
        #expect(row.text("ts") == "text")
        #expect(row.text("tb") == "blob")
    }

    @Test("text with a NUL and with non-ASCII characters is returned intact")
    func textIsBinarySafe() throws {
        let connection = try SQLiteConnection(path: ":memory:")
        try connection.execute("CREATE TABLE t (s TEXT)", [])
        let withNUL = "before\u{0}after"
        let nonASCII = "café, 日本語, emoji 🐝, combining e\u{301}"
        try connection.execute("INSERT INTO t VALUES (?)", [.text(withNUL)])
        try connection.execute("INSERT INTO t VALUES (?)", [.text(nonASCII)])

        let rows = try connection.execute("SELECT s, length(CAST(s AS BLOB)) AS bytes FROM t ORDER BY rowid", [])

        #expect(rows.map { $0.text("s") } == [withNUL, nonASCII])
        #expect(rows[0].integer("bytes") == Int64(withNUL.utf8.count))
        #expect(rows[1].integer("bytes") == Int64(nonASCII.utf8.count))
    }

    @Test("a bind-count mismatch throws .bindCount")
    func bindCountMismatch() throws {
        let connection = try SQLiteConnection(path: ":memory:")
        try connection.execute("CREATE TABLE t (a, b)", [])

        #expect(throws: SQLiteError.bindCount(expected: 2, got: 1)) {
            try connection.execute("INSERT INTO t VALUES (?, ?)", [.integer(1)])
        }
        #expect(throws: SQLiteError.bindCount(expected: 2, got: 3)) {
            try connection.execute("INSERT INTO t VALUES (?, ?)", [.integer(1), .integer(2), .integer(3)])
        }
        #expect(throws: SQLiteError.bindCount(expected: 0, got: 1)) {
            try connection.execute("SELECT 1", [.integer(1)])
        }
        #expect(try connection.execute("SELECT COUNT(*) AS c FROM t", []).first?.integer("c") == 0)
    }

    @Test("a syntax error throws .prepare carrying the SQL")
    func syntaxError() throws {
        let connection = try SQLiteConnection(path: ":memory:")
        let sql = "SELEKT nothing"

        do {
            try connection.execute(sql, [])
            Issue.record("expected a throw")
        } catch let SQLiteError.prepare(sql: carried, message: message) {
            #expect(carried == sql)
            #expect(message.contains("syntax error"))
        }
    }

    @Test("a failed statement leaves the connection usable")
    func failureLeavesConnectionUsable() throws {
        let connection = try SQLiteConnection(path: ":memory:")
        try connection.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL)", [])
        try connection.execute("INSERT INTO t VALUES (1, 'a')", [])

        #expect(throws: SQLiteError.self) { try connection.execute("INSERT INTO t VALUES (1, 'dup')", []) }
        #expect(throws: SQLiteError.self) { try connection.execute("INSERT INTO t VALUES (2, NULL)", []) }
        #expect(throws: SQLiteError.self) { try connection.execute("SELECT * FROM nope", []) }
        #expect(throws: SQLiteError.self) { try connection.execute("INSERT INTO t VALUES (?, ?)", []) }

        try connection.execute("INSERT INTO t VALUES (2, 'b')", [])
        let rows = try connection.execute("SELECT name FROM t ORDER BY id", [])
        #expect(rows.map { $0.text("name") } == ["a", "b"])
        // No transaction was left open by the failures: BEGIN would throw if one were.
        try connection.begin()
        try connection.rollback()
    }

    @Test("a step failure throws .step with SQLite's message")
    func stepError() throws {
        let connection = try SQLiteConnection(path: ":memory:")
        try connection.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)", [])
        try connection.execute("INSERT INTO t VALUES (1)", [])

        do {
            try connection.execute("INSERT INTO t VALUES (1)", [])
            Issue.record("expected a throw")
        } catch let SQLiteError.step(message) {
            #expect(message.contains("UNIQUE"))
        }
    }

    @Test("a script of several statements runs them all in order")
    func scripts() throws {
        let connection = try SQLiteConnection(path: ":memory:")
        try connection.execute("""
            CREATE TABLE t (n INTEGER); -- a comment
            INSERT INTO t VALUES (1);
            INSERT INTO t VALUES (2);
            """, [])

        let rows = try connection.execute("SELECT n FROM t ORDER BY n", [])
        #expect(rows.map { $0.integer("n") } == [1, 2])
    }

    @Test("a script stops at the first failing statement and throws")
    func scriptStopsAtFailure() throws {
        let connection = try SQLiteConnection(path: ":memory:")
        #expect(throws: SQLiteError.self) {
            try connection.execute("CREATE TABLE t (n INTEGER); INSERT INTO nope VALUES (1); CREATE TABLE u (n);", [])
        }
        // The statement before the failure ran (no implicit transaction), the one after did not.
        #expect(try connection.execute("SELECT name FROM sqlite_master WHERE type = 'table'", []).map { $0.text("name") } == ["t"])
    }

    @Test("bindings are only accepted for a single statement")
    func bindingsNeedASingleStatement() throws {
        let connection = try SQLiteConnection(path: ":memory:")
        try connection.execute("CREATE TABLE t (n INTEGER)", [])

        #expect(throws: SQLiteError.self) {
            try connection.execute("INSERT INTO t VALUES (?); INSERT INTO t VALUES (?)", [.integer(1), .integer(2)])
        }
        #expect(throws: SQLiteError.bindCount(expected: 1, got: 0)) {
            try connection.execute("INSERT INTO t VALUES (1); INSERT INTO t VALUES (?)", [])
        }
    }

    @Test("begin, commit and rollback control a transaction")
    func transactions() throws {
        let connection = try SQLiteConnection(path: ":memory:")
        try connection.execute("CREATE TABLE t (n INTEGER)", [])

        try connection.begin()
        try connection.execute("INSERT INTO t VALUES (1)", [])
        try connection.commit()

        try connection.begin()
        try connection.execute("INSERT INTO t VALUES (2)", [])
        try connection.rollback()

        #expect(try connection.execute("SELECT n FROM t", []).map { $0.integer("n") } == [1])
        #expect(throws: SQLiteError.self) { try connection.commit() }
    }

    @Test("foreign keys are enforced")
    func foreignKeys() throws {
        let connection = try SQLiteConnection(path: ":memory:")
        #expect(try connection.execute("PRAGMA foreign_keys", []).first?.integer("foreign_keys") == 1)
    }

    @Test("a file database opens in WAL mode")
    func walMode() throws {
        let file = try TemporaryDatabaseFile()
        defer { file.remove() }
        let connection = try SQLiteConnection(path: file.path)
        #expect(try connection.execute("PRAGMA journal_mode", []).first?.text("journal_mode") == "wal")
    }

    @Test("an unopenable path throws .open")
    func openFailure() throws {
        let path = "/nonexistent-\(UUID().uuidString)/x.db"
        do {
            _ = try SQLiteConnection(path: path)
            Issue.record("expected a throw")
        } catch SQLiteError.open {
            // expected
        }
    }
}

/// A unique database path in the temporary directory; `remove()` deletes it with its WAL and SHM files.
struct TemporaryDatabaseFile {
    let path: String

    init() throws {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("caritos-db-\(UUID().uuidString).sqlite").path
    }

    func remove() {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }
}
