/// One schema step. Once an app version containing it has shipped, never edit it: add a new migration.
public struct Migration: Sendable {
    public let version: Int
    /// A script of one or more statements. It must not contain BEGIN, COMMIT or ROLLBACK: the Migrator
    /// wraps each migration in its own transaction.
    ///
    /// Foreign keys are off while it runs (the Migrator turns them off before the first migration, since
    /// `PRAGMA foreign_keys` is a no-op inside a transaction, and back on after the last), so SQLite's
    /// table rebuild (create new, copy, drop old, rename) does not cascade-delete child rows. Do not set
    /// `PRAGMA foreign_keys` here. Each migration must leave every reference valid: `PRAGMA
    /// foreign_key_check` runs inside its transaction before the version bump, and a violation fails it.
    public let sql: String

    /// `version` is the `PRAGMA user_version` the database has after this migration runs.
    public init(version: Int, sql: String) {
        self.version = version
        self.sql = sql
    }
}

public enum MigrationError: Error, Equatable {
    /// The migration list is empty, or versions are not positive and strictly increasing.
    case invalidList(String)
    /// The database was written by a newer app version than this one understands.
    case databaseIsNewer(found: Int, supported: Int)
    /// A migration failed; it was rolled back and the database stays at the previous version.
    case failed(version: Int, message: String)
}

/// Brings a database up to the latest schema using `PRAGMA user_version`. Each pending migration runs
/// in its own transaction together with its version bump, so a failure leaves the database at the last
/// version that fully applied. The whole run holds the `Database` actor with foreign keys off (see
/// `Migration.sql`) and restores them afterwards, also on failure.
public struct Migrator: Sendable {
    private let migrations: [Migration]

    public init(_ migrations: [Migration]) throws {
        guard let first = migrations.first else {
            throw MigrationError.invalidList("the migration list is empty")
        }
        guard first.version > 0 else {
            throw MigrationError.invalidList("version \(first.version) must be greater than 0")
        }
        for (previous, next) in zip(migrations, migrations.dropFirst()) where next.version <= previous.version {
            throw MigrationError.invalidList(
                "version \(next.version) must be greater than the one before it (\(previous.version))")
        }
        self.migrations = migrations
    }

    public func migrate(_ database: Database) async throws {
        try await database.withForeignKeysOff { db in try self.migrateAll(db) }
    }

    private func migrateAll(_ database: isolated Database) throws {
        let current = try database.execute("PRAGMA user_version").first?.integer("user_version") ?? 0
        let latest = migrations[migrations.count - 1].version
        if current > Int64(latest) {
            throw MigrationError.databaseIsNewer(found: Int(current), supported: latest)
        }
        for migration in migrations where Int64(migration.version) > current {
            try applyIfPending(migration, to: database)
        }
    }

    /// Runs one migration, a foreign key check and its version bump in a single transaction. The version
    /// is re-read inside the transaction (which holds the write lock), so a migration that another
    /// Migrator on the same file applied after our first read is skipped instead of run twice.
    func applyIfPending(_ migration: Migration, to database: isolated Database) throws {
        do {
            try database.transaction { tx in
                let applied = try tx.execute("PRAGMA user_version").first?.integer("user_version") ?? 0
                if applied >= Int64(migration.version) { return }
                try tx.execute(migration.sql)
                let violations = try tx.execute("PRAGMA foreign_key_check")
                if let first = violations.first {
                    throw MigrationError.failed(version: migration.version, message:
                        "foreign key check failed: \(violations.count) row(s), the first in "
                        + "\(first.text("table") ?? "?") referencing a missing \(first.text("parent") ?? "?") row")
                }
                // PRAGMA cannot take bound values; the number is a validated Int, not user text.
                try tx.execute("PRAGMA user_version = \(migration.version)")
            }
        } catch let error as MigrationError {
            throw error
        } catch {
            throw MigrationError.failed(version: migration.version, message: String(describing: error))
        }
    }
}
