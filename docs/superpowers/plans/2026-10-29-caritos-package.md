# Caritos Package Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the shared Swift package `Caritos` at `ios/Caritos/` in lotus and make `new-ios-app` scaffold apps that depend on it.

**Architecture:** One local SwiftPM package with six independent library targets (database, security, networking, logging, UI, storage), each ported from the best existing copy in the author's apps and rewritten test-first. `new-ios-app` copies the package into a new app's `ios/Caritos/` and the app's Kit depends on it by relative path. No existing app is changed.

**Tech Stack:** Swift 5.9 tools, Swift Testing, system `libsqlite3`, Security framework, SwiftUI, bash for the scaffold and its tests, XcodeGen (already used by the scaffold).

**Spec:** `docs/superpowers/specs/2026-10-29-caritos-design.md`

## Global Constraints

- Package: `ios/Caritos/Package.swift`, name `Caritos`, `// swift-tools-version: 5.9`, `platforms: [.iOS(.v17), .macOS(.v14)]` so `swift test` runs on the Mac. Swift language mode 5; strict concurrency warnings on, errors off.
- Six library products, one target each, named exactly: `CaritosDatabase`, `CaritosSecurity`, `CaritosNetworking`, `CaritosLogging`, `CaritosUI`, `CaritosStorage`. Test targets are `<Target>Tests`.
- System `libsqlite3` only (no GRDB). Not an ORM. A single actor owns the connection.
- Test framework is Swift Testing (`import Testing`, `@Test`, `#expect`). Test first (red, green, refactor), one commit per green step.
- A type goes in only because two apps already hold a copy of it. Public API stays small; everything else `internal`.
- The package never logs secrets; Keychain errors never contain the value.
- Existing databases must upgrade in place; a test upgrades a database created with the previous schema.
- No existing app changes in this plan. Nothing is pushed.
- Commit trailers: `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01D4JSV5enaQG3rHHhHSJ7UX`.
- Port from these bases (read them, keep their behavior, rewrite test-first; the survey that named them was not fully verified, so check each exists first and report if not):
  - SQLite: `~/src/fressh/ios/Sources/FresshKit/Database/` (`SQLiteConnection.swift`, `DatabaseLocation.swift`, `Migrations.swift`) and concurrency tests in `~/src/busy-hive/ios/Tests/HiveKitTests/` (`SQLiteConnectionTests`).
  - Keychain: `~/src/busy-hive/ios/Sources/HiveKit/Auth/KeychainPinStore.swift`, `~/src/caritos-com/ios/Packages/TravelBlogKit/` or `.../TravelBlog/KeychainStore.swift`, `~/src/hop/Terminal/HostStore.swift`.
  - Networking: `APIClient.swift`, `APIError.swift` and the `HTTPTransport` protocol in `~/src/caritos-com/ios/`.
  - Logging: `~/src/fressh/ios/Sources/FresshKit/FileLogger.swift`.
  - Storage: `~/src/ancient-art-of-war/Sources/AoWScenarios/SaveStore.swift`.
  - UI: `Color(hex:)` in `~/src/fressh/.../Theme.swift`; `SettingsRow` in `~/src/fressh/.../SettingsView.swift`; `Haptics.swift` in `~/src/spool/` and `~/src/pusoy-dos/`.

## Review Focus

- A database whose `user_version` is newer than the app's latest migration: `Migrator` must throw `databaseIsNewer` and change nothing, not downgrade or silently proceed (Task 6).
- A migration that fails halfway: the whole step rolls back and `user_version` is unchanged (Task 6).
- A truncated, empty or wrong-version JSON file: `JSONFileStore.load()` moves it aside and returns nil; the next `save` works and the corrupt copy is kept (Task 7).
- A missing Keychain item: `read` returns nil, not a throw; a Keychain failure carries a status code and no secret (Task 2).
- Two concurrent tasks writing the same table, a bind-count mismatch, and a text value containing a NUL or non-ASCII characters: serialized, thrown, and round-tripped intact (Task 5).

---

### Task 1: Package skeleton and the layout guard

**Files:**
- Create: `ios/Caritos/Package.swift`, `ios/Caritos/README.md`, and one placeholder source plus one placeholder test per target (`Sources/<Target>/<Target>.swift` holding `enum <Target>Marker {}`; `Tests/<Target>Tests/MarkerTests.swift`)
- Modify: `web/scripts/layout.test.sh` (starter-only section near line 104-110), `.gitignore`
- Test: `web/scripts/layout.test.sh`

**Interfaces:**
- Produces: the six targets and products named in Global Constraints; later tasks replace each marker file.

- [ ] **Step 1: Write the failing guard check.** In the starter-only section of `layout.test.sh`, assert `ios/Caritos/Package.swift` is tracked and lists all six product names, and that no `.build/` or `.swiftpm/` path under `ios/` is tracked. Add self-tests like the existing ones proving each assertion fires (remove a product line, track a `.build/x`).
- [ ] **Step 2: Run `bash web/scripts/layout.test.sh`.** Expected: FAIL naming `ios/Caritos/Package.swift`.
- [ ] **Step 3: Create the package.** `Package.swift` declares the six libraries and test targets; `CaritosDatabase` links `sqlite3` via `linkerSettings: [.linkedLibrary("sqlite3")]`; each marker test is `@Test func targetBuilds() { #expect(true) }`. `README.md` lists the products and the rule "a type goes in only when two apps hold a copy". Add `ios/Caritos/.build/` and `.swiftpm/` to `.gitignore`.
- [ ] **Step 4: Run `cd ios/Caritos && swift test` and `bash web/scripts/layout.test.sh`.** Expected: all tests pass, 0 failures.
- [ ] **Step 5: Commit** "Caritos: package skeleton and layout guard".

### Task 2: CaritosSecurity (KeychainStore)

**Files:**
- Create: `Sources/CaritosSecurity/{SecretStoring,KeychainStore,InMemorySecretStore}.swift`
- Test: `Tests/CaritosSecurityTests/SecretStoreTests.swift`

**Interfaces:**
- Produces:
  - `public protocol SecretStoring: Sendable { func read(account: String) throws -> String?; func write(_ value: String, account: String) throws; func delete(account: String) throws }`
  - `public struct KeychainStore: SecretStoring { public init(service: String) }` (generic password items, accessible after first unlock; accounts are stable UUID strings by convention)
  - `public final class InMemorySecretStore: SecretStoring` (for tests of apps)
  - `public enum KeychainError: Error, Equatable { case unexpectedStatus(Int32) }`

- [ ] **Step 1: Write failing tests against `InMemorySecretStore`** for write-then-read, overwrite, delete, and `read` of a missing account returning nil; plus a test that `KeychainError.unexpectedStatus(-25300).localizedDescription` contains the status and never a value.
- [ ] **Step 2: Run `swift test --filter CaritosSecurityTests`.** Expected: FAIL (types undefined).
- [ ] **Step 3: Implement the protocol, `InMemorySecretStore` and `KeychainError`.** Run; expected PASS. Commit.
- [ ] **Step 4: Write a failing real-Keychain test** (same behaviors, a unique `service` per run, cleans up), enabled only when env `CARITOS_REAL_KEYCHAIN=1`, so the default run stays hermetic.
- [ ] **Step 5: Implement `KeychainStore`** with `SecItemAdd`/`SecItemCopyMatching`/`SecItemUpdate`/`SecItemDelete`; `errSecItemNotFound` maps to nil / no-op delete; other statuses throw `KeychainError`. Run with `CARITOS_REAL_KEYCHAIN=1 swift test --filter CaritosSecurityTests`; record whether it passed on this Mac, or that it needs the app host. Commit.

### Task 3: CaritosLogging (FileLogger)

**Files:**
- Create: `Sources/CaritosLogging/{LogLevel,FileLogger}.swift`
- Test: `Tests/CaritosLoggingTests/FileLoggerTests.swift`

**Interfaces:**
- Produces:
  - `public enum LogLevel: Int, Comparable, Sendable { case debug, info, warning, error }`
  - `public final class FileLogger: @unchecked Sendable { public init(directory: URL, minimumLevel: LogLevel = .info, subsystem: String = "com.caritos", now: @escaping @Sendable () -> Date = Date.init); public func log(_ level: LogLevel, _ message: String); public var fileURL: URL { get }; public func exportURLs() -> [URL] }`

- [ ] **Step 1: Write failing tests** (temp directory, injected clock): a line below the minimum level is not written; lines carry timestamp, level and message in order; a second `FileLogger` on the same directory writes a new session file and `exportURLs()` lists both, newest first; an unwritable directory makes `log` a silent no-op that does not crash (Review Focus).
- [ ] **Step 2: Run; expected FAIL. Step 3: Implement** by porting fressh's `FileLogger` (lock, one file per session) and also forwarding to `os.Logger(subsystem:category:)`. Run; expected PASS.
- [ ] **Step 4: Commit.**

### Task 4: CaritosNetworking

**Files:**
- Create: `Sources/CaritosNetworking/{HTTPTransport,URLSessionTransport,APIError}.swift`
- Test: `Tests/CaritosNetworkingTests/{APIErrorTests,URLSessionTransportTests}.swift`

**Interfaces:**
- Produces:
  - `public protocol HTTPTransport: Sendable { func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) }`
  - `public struct URLSessionTransport: HTTPTransport { public init(session: URLSession = .shared) }`
  - `public enum APIError: Error, Equatable { case notConfigured, unauthorized, server(status: Int, message: String?), network(String), invalidResponse; public var isTransient: Bool; public static func check(_ data: Data, _ response: HTTPURLResponse) throws }`

- [ ] **Step 1: Write failing tests**: `check` passes 200-299, throws `.unauthorized` for 401, `.server(status:message:)` for 4xx/5xx using a JSON `{"error": "..."}` body when present and nil otherwise; `isTransient` is true for `.network` and 5xx, false for 401 and 4xx; `URLSessionTransport` against a `URLProtocol` stub returns data and response, and maps a non-HTTP response to `.invalidResponse`.
- [ ] **Step 2: Run; expected FAIL. Step 3: Implement**, porting caritos-com's `APIError` cases and `isTransient`. Run; expected PASS.
- [ ] **Step 4: Commit.**

### Task 5: CaritosDatabase, part 1 (connection and Database actor)

**Files:**
- Create: `Sources/CaritosDatabase/{SQLiteValue,SQLiteRow,SQLiteError,SQLiteConnection,Database,DatabaseLocation}.swift`
- Test: `Tests/CaritosDatabaseTests/{SQLiteConnectionTests,DatabaseTests}.swift`

**Interfaces:**
- Produces:
  - `public enum SQLiteValue: Equatable, Sendable { case null, integer(Int64), real(Double), text(String), blob(Data) }`
  - `public struct SQLiteRow: Sendable { public subscript(column: String) -> SQLiteValue? { get }; public func text(_ column: String) -> String?; public func integer(_ column: String) -> Int64? }`
  - `public enum SQLiteError: Error, Equatable { case open(String), prepare(sql: String, message: String), step(String), bindCount(expected: Int, got: Int) }`
  - `final class SQLiteConnection` (internal, not Sendable): `init(path: String) throws`, `func execute(_ sql: String, _ bindings: [SQLiteValue]) throws -> [SQLiteRow]`, `func begin() / commit() / rollback()`. Statements are always finalized (`defer`).
  - `public actor Database { public init(path: String) throws; public static func inMemory() throws -> Database; public func execute(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> [SQLiteRow]; public func transaction<T: Sendable>(_ body: (Transaction) throws -> T) throws -> T }`, where `public struct Transaction { public func execute(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> [SQLiteRow] }`
  - `public enum DatabaseLocation { public static func applicationSupport(file: String) throws -> URL }`

- [ ] **Step 1: Write failing connection tests** (port busy-hive's and fressh's `SQLiteConnectionTests`): round-trip every `SQLiteValue` case; text with a NUL and with non-ASCII characters is returned intact (Review Focus); bind-count mismatch throws `.bindCount`; a syntax error throws `.prepare` carrying the SQL; a failed statement leaves the connection usable (statements finalized).
- [ ] **Step 2: Write failing `Database` tests:** `transaction` commits on success and rolls back everything when the body throws; 50 concurrent `execute` increments of one counter row from a `TaskGroup` end at exactly 50 (Review Focus); `DatabaseLocation` returns a URL inside Application Support and creates the directory.
- [ ] **Step 3: Run; expected FAIL. Step 4: Implement** from fressh's `SQLiteConnection` (its `execute(sql, bindings:)` returning dictionary rows becomes `SQLiteRow`), `Database` as an actor owning the connection. Run; expected PASS.
- [ ] **Step 5: Commit.**

### Task 6: CaritosDatabase, part 2 (Migrator)

**Files:**
- Create: `Sources/CaritosDatabase/Migrator.swift`
- Test: `Tests/CaritosDatabaseTests/MigratorTests.swift`

**Interfaces:**
- Consumes: `Database` from Task 5.
- Produces:
  - `public struct Migration: Sendable { public init(version: Int, sql: String) }`
  - `public struct Migrator: Sendable { public init(_ migrations: [Migration]) throws; public func migrate(_ database: Database) async throws }` using `PRAGMA user_version`; each migration runs in its own transaction together with its version bump.
  - `public enum MigrationError: Error, Equatable { case invalidList(String), databaseIsNewer(found: Int, supported: Int), failed(version: Int, message: String) }`

- [ ] **Step 1: Write failing tests:** a fresh database ends at the latest version; running twice is a no-op; **upgrade test**: build a database file with only migration 1 (the "previous schema") holding a row, then migrate with 1 and 2 and assert the row survived and the new column exists; `user_version` above the latest throws `databaseIsNewer` and changes nothing; a migration whose second statement fails leaves the earlier statements of that same migration rolled back and `user_version` unchanged (Review Focus); an empty, duplicate or non-increasing version list throws `invalidList` from `init`.
- [ ] **Step 2: Run; expected FAIL. Step 3: Implement.** Plan call (mine): no per-file checksum (YAGNI; "immutable once released" is enforced by the upgrade test convention). Run; expected PASS.
- [ ] **Step 4: Commit.**

### Task 7: CaritosStorage (JSONFileStore)

**Files:**
- Create: `Sources/CaritosStorage/JSONFileStore.swift`
- Test: `Tests/CaritosStorageTests/JSONFileStoreTests.swift`

**Interfaces:**
- Produces: `public struct JSONFileStore<Value: Codable & Sendable>: Sendable { public init(directory: URL, name: String, version: Int); public func load() throws -> Value?; public func save(_ value: Value) throws }`. The file is `<name>.json` holding `{"version": N, "value": ...}`; writes are atomic; a corrupt or wrong-version file is moved to `<name>.corrupt.json` and `load` returns nil.

- [ ] **Step 1: Write failing tests:** save then load round-trips; load of a missing file is nil and creates nothing; an empty file, a truncated file, and a file with a different `version` each return nil, leave `<name>.corrupt.json` with the original bytes, and a following `save`/`load` works (Review Focus); a failed write (read-only directory) throws and leaves the previous file intact.
- [ ] **Step 2: Run; expected FAIL. Step 3: Implement** from AoW's `SaveStore`. Run; expected PASS. Commit.

### Task 8: CaritosUI

**Files:**
- Create: `Sources/CaritosUI/{HexColor,ErrorBanner,EmptyStateView,SettingsRow,Haptics}.swift`
- Test: `Tests/CaritosUITests/HexColorTests.swift`

**Interfaces:**
- Produces:
  - `public enum HexColor { public static func components(_ hex: UInt32) -> (red: Double, green: Double, blue: Double) }` (pure, tested) and `public extension Color { init(hex: UInt32) }` (sRGB)
  - `public struct ErrorBanner: View { public init(message: String, retry: (() -> Void)? = nil) }`
  - `public struct EmptyStateView: View { public init(title: String, message: String? = nil, systemImage: String) }`
  - `public struct SettingsRow: View { public init(title: String, value: String? = nil) }`
  - `public enum Haptics { public static func success(); public static func selection() }` (a no-op off iOS, behind `#if canImport(UIKit)`)

- [ ] **Step 1: Write the failing test:** `components(0xFF8000)` is (1.0, 128/255, 0.0) and `0x000000` is all zeros.
- [ ] **Step 2: Run; expected FAIL. Step 3: Implement `HexColor` and the extension. Run; PASS. Commit.**
- [ ] **Step 4: Add the three views and `Haptics`,** ported from fressh and spool/pusoy-dos (styling and copy changes need no failing test; confirm the target builds with `swift build`, and `xcodebuild -scheme CaritosUI -destination 'generic/platform=iOS Simulator' build` from `ios/Caritos`). Plan call (mine): `Haptics` ships in the first release because two apps hold a copy. Commit.

### Task 9: Scaffold copies Caritos and apps depend on it

**Files:**
- Create: `.claude/skills/new-ios-app/tests/scaffold.test.sh` (`--fast` skips the `swift test` step), `.claude/skills/new-ios-app/templates/kit/CaritosLinkTests.swift`
- Modify: `.claude/skills/new-ios-app/scripts/scaffold.sh`, `.claude/skills/new-ios-app/templates/Package.swift`, `.claude/skills/new-ios-app/SKILL.md`, `.claude/skills/new-web-app/scripts/scaffold.sh` (line ~107: also `rm -rf "$W/ios/Caritos"`), `.claude/skills/new-web-app/tests/scaffold.test.sh`
- Modify: `web/Makefile` (`test-skills` also runs the new-ios-app fast tier)

**Interfaces:**
- Consumes: the package from Tasks 1-8.
- Produces: `scaffold.sh` copies `<lotus>/ios/Caritos` (excluding `.build`, `.swiftpm`) to `$IOS/Caritos`, resolving the lotus root through symlinks as `new-web-app`'s scaffold does (`~/.claude/skills/new-ios-app` is a symlink); the template `Package.swift` adds `dependencies: [.package(path: "Caritos")]` and makes `__APP__Kit` depend on `.product(name: "CaritosLogging", package: "Caritos")`; the template test `CaritosLinkTests` imports `CaritosLogging` and asserts `LogLevel.error > LogLevel.debug`.

- [ ] **Step 1: Write the failing scaffold test:** scaffold an app into a temp directory (once, through a symlinked skill path to cover the symlink case) and assert `ios/Caritos/Package.swift` exists, `ios/Caritos/.build` does not, the app's `Package.swift` names the `Caritos` path package, and (full tier) `cd ios && swift test` passes including `CaritosLinkTests`.
- [ ] **Step 2: Write the failing web-wrapper test:** a web app scaffolded from the starter has no `ios/Caritos`.
- [ ] **Step 3: Run both; expected FAIL. Step 4: Implement** the scaffold copy, template changes and the wrapper exclusion; document the flow in `SKILL.md` ("Caritos package": what it contains, that the copy is a snapshot, fixes go to lotus first). Run both tiers; expected PASS. Commit.

### Task 10: Docs, log, and verification

**Files:**
- Modify: `CLAUDE.md` (layout block gets `ios/Caritos/`, a Done entry dated 2026-10-29, and Deferred: `sync-caritos.sh`, per-app adoption starting with Stark, `HTTPTransport` stub for apps), `ios/README.md`, `web/docs/testing.md` (mention the new-ios-app tests)

- [ ] **Step 1: Update the docs; `grep -rn "CaritosKit\|CaritosPackage" .` returns nothing outside `docs/superpowers/` history.**
- [ ] **Step 2: Run, and report each result honestly:** `cd ios/Caritos && swift test`; `CARITOS_REAL_KEYCHAIN=1 swift test --filter CaritosSecurityTests`; `bash .claude/skills/new-ios-app/tests/scaffold.test.sh`; `make -C web test-scripts`; `bash .claude/skills/new-web-app/tests/run.sh` (full tier). Use Node 24 and the corepack pnpm shim as in earlier sessions; run long suites in the background.
- [ ] **Step 3: Commit.** Merge back locally after the full suite passes on the merged result. Ask before pushing.

---

## Self-review

- **Spec coverage:** all six products (Tasks 2-8), `Migrator` upgrade test, concurrency test, real-Keychain test gated by env, location in lotus with the layout guard (Task 1), scaffold dependency and smoke test of one product (Task 9), no app adoption (Global Constraints), Stark and the sync script recorded as deferred (Task 10).
- **Types:** `Database`, `Transaction`, `SQLiteRow`, `SQLiteValue`, `Migration`, `Migrator`, `SecretStoring`, `LogLevel` are named identically across tasks.
- **Proportion:** the plan holds signatures and assertions only; bodies are left to the implementer and the named base files.
