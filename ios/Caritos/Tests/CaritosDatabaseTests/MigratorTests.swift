import Foundation
import Testing
import CaritosDatabase

@Suite("Migrator")
struct MigratorTests {
    private static let m1 = Migration(version: 1, sql: "CREATE TABLE note (id TEXT PRIMARY KEY, title TEXT NOT NULL);")
    private static let m2 = Migration(version: 2, sql: "ALTER TABLE note ADD COLUMN body TEXT;")

    private func version(_ database: Database) async throws -> Int64? {
        try await database.execute("PRAGMA user_version").first?.integer("user_version")
    }

    private func tempPath() -> String {
        NSTemporaryDirectory() + "migrator-\(UUID().uuidString).sqlite"
    }

    private func removeFiles(_ path: String) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    @Test("a fresh database ends at the latest version")
    func freshDatabase() async throws {
        let database = try Database.inMemory()
        try await Migrator([Self.m1, Self.m2]).migrate(database)

        #expect(try await version(database) == 2)
        try await database.execute("INSERT INTO note (id, title, body) VALUES ('a', 't', 'b')")
    }

    @Test("running twice is a no-op")
    func runningTwice() async throws {
        let database = try Database.inMemory()
        let migrator = try Migrator([Self.m1, Self.m2])
        try await migrator.migrate(database)
        try await database.execute("INSERT INTO note (id, title) VALUES ('a', 't')")
        try await migrator.migrate(database)

        #expect(try await version(database) == 2)
        #expect(try await database.execute("SELECT id FROM note").count == 1)
    }

    @Test("a database at migration 1 upgrades in place and keeps its data")
    func upgradeFromPreviousSchema() async throws {
        let path = tempPath()
        defer { removeFiles(path) }

        do {
            let old = try Database(path: path)
            try await Migrator([Self.m1]).migrate(old)
            try await old.execute("INSERT INTO note (id, title) VALUES ('a', 'kept')")
            #expect(try await version(old) == 1)
        }

        let upgraded = try Database(path: path)
        try await Migrator([Self.m1, Self.m2]).migrate(upgraded)

        #expect(try await version(upgraded) == 2)
        let rows = try await upgraded.execute("SELECT id, title, body FROM note")
        #expect(rows.count == 1)
        #expect(rows.first?.text("title") == "kept")
        #expect(rows.first?.text("body") == nil)
        let columns = try await upgraded.execute("PRAGMA table_info(note)").compactMap { $0.text("name") }
        #expect(columns == ["id", "title", "body"])
    }

    @Test("a database newer than the app throws and changes nothing")
    func databaseIsNewer() async throws {
        let database = try Database.inMemory()
        try await database.execute("CREATE TABLE keep (n INTEGER)")
        try await database.execute("PRAGMA user_version = 5")

        await #expect(throws: MigrationError.databaseIsNewer(found: 5, supported: 2)) {
            try await Migrator([Self.m1, Self.m2]).migrate(database)
        }

        #expect(try await version(database) == 5)
        let tables = try await database.execute("SELECT name FROM sqlite_master WHERE type = 'table'")
        #expect(tables.compactMap { $0.text("name") } == ["keep"])
    }

    @Test("a failing migration rolls back all of its statements and leaves the version alone")
    func failureRollsBack() async throws {
        let database = try Database.inMemory()
        let bad = Migration(version: 2, sql: """
            ALTER TABLE note ADD COLUMN body TEXT;
            CREATE TABLE extra (n INTEGER);
            INSERT INTO missing_table VALUES (1);
            """)

        await #expect {
            try await Migrator([Self.m1, bad]).migrate(database)
        } throws: { error in
            guard case MigrationError.failed(let version, let message) = error else { return false }
            return version == 2 && !message.isEmpty
        }

        #expect(try await version(database) == 1)
        #expect(try await database.execute("SELECT name FROM sqlite_master WHERE name = 'extra'").isEmpty)
        let columns = try await database.execute("PRAGMA table_info(note)").compactMap { $0.text("name") }
        #expect(columns == ["id", "title"])
    }

    @Test("an invalid list is rejected by init", arguments: [
        [Migration](),
        [Migration(version: 1, sql: "SELECT 1"), Migration(version: 1, sql: "SELECT 1")],
        [Migration(version: 2, sql: "SELECT 1"), Migration(version: 1, sql: "SELECT 1")],
        [Migration(version: 0, sql: "SELECT 1")],
        [Migration(version: -1, sql: "SELECT 1")],
    ])
    func invalidList(list: [Migration]) {
        #expect {
            try Migrator(list)
        } throws: { error in
            if case MigrationError.invalidList = error { return true }
            return false
        }
    }

    @Test("gaps in the version numbers are allowed")
    func gapsAllowed() async throws {
        let database = try Database.inMemory()
        try await Migrator([Migration(version: 1, sql: "SELECT 1"), Migration(version: 5, sql: "SELECT 1")]).migrate(database)
        #expect(try await version(database) == 5)
    }
}
