import Foundation
import Testing
import CaritosDatabase

@Suite("Database")
struct DatabaseTests {
    private struct Boom: Error {}

    @Test("execute binds values and returns rows")
    func executeReturnsRows() async throws {
        let database = try Database.inMemory()
        try await database.execute("CREATE TABLE t (id TEXT PRIMARY KEY, n INTEGER)")
        try await database.execute("INSERT INTO t VALUES (?, ?)", [.text("a"), .integer(7)])

        let rows = try await database.execute("SELECT id, n FROM t WHERE id = ?", [.text("a")])

        #expect(rows.count == 1)
        #expect(rows.first?.text("id") == "a")
        #expect(rows.first?.integer("n") == 7)
    }

    @Test("transaction commits every statement on success and returns the body's value")
    func transactionCommits() async throws {
        let database = try Database.inMemory()
        try await database.execute("CREATE TABLE t (n INTEGER)")

        let count = try await database.transaction { tx in
            try tx.execute("INSERT INTO t VALUES (?)", [.integer(1)])
            try tx.execute("INSERT INTO t VALUES (?)", [.integer(2)])
            return try tx.execute("SELECT COUNT(*) AS c FROM t").first?.integer("c")
        }

        #expect(count == 2)
        #expect(try await database.execute("SELECT n FROM t ORDER BY n").map { $0.integer("n") } == [1, 2])
    }

    @Test("transaction rolls back everything when the body throws")
    func transactionRollsBackOnThrow() async throws {
        let database = try Database.inMemory()
        try await database.execute("CREATE TABLE t (n INTEGER)")
        try await database.execute("INSERT INTO t VALUES (0)")

        await #expect(throws: Boom.self) {
            try await database.transaction { tx in
                try tx.execute("INSERT INTO t VALUES (1)")
                try tx.execute("UPDATE t SET n = n + 100")
                try tx.execute("CREATE TABLE u (n INTEGER)")
                throw Boom()
            }
        }

        #expect(try await database.execute("SELECT n FROM t").map { $0.integer("n") } == [0])
        #expect(try await database.execute("SELECT name FROM sqlite_master WHERE name = 'u'").isEmpty)
        // The database is usable and not stuck inside the failed transaction.
        try await database.transaction { tx in try tx.execute("INSERT INTO t VALUES (2)") }
        #expect(try await database.execute("SELECT COUNT(*) AS c FROM t").first?.integer("c") == 2)
    }

    @Test("transaction rolls back when a statement inside it fails")
    func transactionRollsBackOnSQLError() async throws {
        let database = try Database.inMemory()
        try await database.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)")

        await #expect(throws: SQLiteError.self) {
            try await database.transaction { tx in
                try tx.execute("INSERT INTO t VALUES (1)")
                try tx.execute("INSERT INTO t VALUES (1)")
            }
        }

        #expect(try await database.execute("SELECT COUNT(*) AS c FROM t").first?.integer("c") == 0)
    }

    @Test("50 concurrent increments of one counter row end at exactly 50")
    func concurrentIncrements() async throws {
        let file = try TemporaryDatabaseFile()
        defer { file.remove() }
        let database = try Database(path: file.path)
        try await database.execute("CREATE TABLE counter (id INTEGER PRIMARY KEY, n INTEGER NOT NULL)")
        try await database.execute("INSERT INTO counter VALUES (1, 0)")

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    try await database.execute("UPDATE counter SET n = n + 1 WHERE id = ?", [.integer(1)])
                }
            }
            try await group.waitForAll()
        }

        #expect(try await database.execute("SELECT n FROM counter").first?.integer("n") == 50)
    }

    @Test("50 concurrent read-modify-write transactions lose no update")
    func concurrentReadModifyWrite() async throws {
        let file = try TemporaryDatabaseFile()
        defer { file.remove() }
        let database = try Database(path: file.path)
        try await database.execute("CREATE TABLE counter (id INTEGER PRIMARY KEY, n INTEGER NOT NULL)")
        try await database.execute("INSERT INTO counter VALUES (1, 0)")

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    try await database.transaction { tx in
                        let current = try tx.execute("SELECT n FROM counter WHERE id = 1").first?.integer("n") ?? -1
                        try tx.execute("UPDATE counter SET n = ? WHERE id = 1", [.integer(current + 1)])
                    }
                }
            }
            try await group.waitForAll()
        }

        #expect(try await database.execute("SELECT n FROM counter").first?.integer("n") == 50)
    }

    @Test("data written to a file database is there after reopening")
    func fileDatabasePersists() async throws {
        let file = try TemporaryDatabaseFile()
        defer { file.remove() }
        do {
            let database = try Database(path: file.path)
            try await database.execute("CREATE TABLE t (s TEXT)")
            try await database.execute("INSERT INTO t VALUES (?)", [.text("kept")])
        }

        let reopened = try Database(path: file.path)
        #expect(try await reopened.execute("SELECT s FROM t").first?.text("s") == "kept")
    }
}

@Suite("DatabaseLocation")
struct DatabaseLocationTests {
    @Test("applicationSupport returns a URL inside Application Support and creates its directory")
    func applicationSupport() throws {
        let folder = "caritos-tests-\(UUID().uuidString)"
        let supportDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )
        defer { try? FileManager.default.removeItem(at: supportDirectory.appendingPathComponent(folder)) }

        let url = try DatabaseLocation.applicationSupport(file: "\(folder)/app.sqlite")

        #expect(url.lastPathComponent == "app.sqlite")
        #expect(url.standardizedFileURL.path.hasPrefix(supportDirectory.standardizedFileURL.path + "/"))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("applicationSupport with a bare file name points directly into Application Support")
    func bareFileName() throws {
        let supportDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )

        let url = try DatabaseLocation.applicationSupport(file: "app.sqlite")

        #expect(url.deletingLastPathComponent().standardizedFileURL.path == supportDirectory.standardizedFileURL.path)
    }
}
