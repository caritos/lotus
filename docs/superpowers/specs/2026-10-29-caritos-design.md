# Caritos: one shared Swift package for the iOS apps

Status: updated after review. Date: 2026-10-29. Source: a read-only survey of busy-hive, fressh, stark, spool,
caritos-com, pusoy-dos, book-reader, ancient-art-of-war, hop and analyze-tennis-stroke. The survey was done
by subagents and not every claim was verified; the first plan task re-checks the files named here.

Name: the package is called **Caritos** (the author's choice; earlier notes say `CaritosKit`). It is a single
string in `Package.swift` and the docs, so a rename is cheap.

## Intent

Every iOS app copies the same infrastructure code and fixes bugs in one copy only. Three SQLite wrappers, four
Keychain stores, two logger approaches, and scripts that drifted from the template exist today. One tested
package, used by every app, means a bug is fixed once and a new app starts with the best version.

## Goals

1. A local SwiftPM package `Caritos`, at `ios/Caritos/` in this repo (swift-tools 5.9, `.iOS(.v17)`, `.macOS(.v14)` so `swift test`
   runs on the Mac) with these products, each its own library target so an app imports only what it uses:
   - `CaritosDatabase`: `SQLiteConnection` (prepared statements, typed bindings, row decoding, transactions,
     statements always finalized, errors thrown), `Migrator` using `PRAGMA user_version` with versioned,
     immutable migrations, and `DatabaseLocation`. Base: fressh's `execute` + `SQLiteValue` + `inTransaction`.
     A single owner (actor) holds the connection. Not an ORM.
   - `CaritosSecurity`: `KeychainStore`, throwing, keyed by a stable UUID, service name as a parameter.
   - `CaritosNetworking`: `HTTPTransport` protocol, `URLSessionTransport`, `APIError` (base: caritos-com's
     `notConfigured`, `unauthorized`, `server(status, message)`, `network`, `invalidResponse`, `isTransient`).
   - `CaritosLogging`: `FileLogger` with levels and export (base: fressh), also writing to `os.Logger`.
   - `CaritosUI`: `Color(hex:)`, `ErrorBanner`, `EmptyStateView`, `SettingsRow`, `Haptics`.
   - `CaritosStorage`: `JSONFileStore` (atomic write, version header, corrupt file moved aside; base:
     ancient-art-of-war's `SaveStore`).
2. Every product is test-first, with in-memory or fake seams, and its tests run with `swift test`.
3. The `new-ios-app` skill scaffolds an app that depends on the package, and its full tier proves the scaffold
   builds and tests.
4. Existing apps may adopt it later, one at a time, each in its own branch with its own tests as the safety
   net. That is not part of the first plan (see Adoption).

## Non-goals

- No ORM, no migration of apps to a different persistence model (book-reader keeps SwiftData).
- No game, terminal or reader-specific UI. Theme palettes stay per app.
- No forced move of every app at once, and no big-bang rewrite. Legacy apps may stay on their own copies.
- No networking beyond the transport and error types (no generated client; that is a separate decision).
- Android: out of scope.

## Anti-goals (failures even if tests pass)

- The package grows into a grab bag. A type goes in only when two apps already hold a copy of it.
- An app that adopts it loses behavior (fressh's migrations, busy-hive's concurrency tests, spool's schema).
- Breaking change to a released migration. Existing databases must upgrade in place; a test upgrades a real
  database from the app's previous schema, not only a fresh one.

## Constraints

- Where it lives (decided by the author): in lotus, at `ios/Caritos/`, because lotus is the template for the iOS
  apps as well as the web apps. No separate repo. `ios/Caritos/` has its own `Package.swift`; the `new-ios-app`
  refusal rule (an `ios/Package.swift` or an Xcode project) is not triggered by a nested package, and
  `web/scripts/layout.test.sh` must be updated to allow `ios/Caritos/` (test first).
- How an app gets it (my call): `new-ios-app` copies `ios/Caritos/` from lotus's committed `HEAD` into the new
  app's `ios/Caritos/` and the Kit depends on it by relative path, so the app builds on any machine and in CI.
  The copy is a snapshot; a small `sync-caritos.sh` (later) re-copies a newer version. Fixes are made in lotus
  first, test first.
- Swift language mode 5 for the package (matches most apps); strict concurrency warnings on, errors off.
  Revisit when the apps move to Swift 6 (my call).
- System `libsqlite3` only; no GRDB. UUID text keys, Unix-ms timestamps, money in cents, soft delete via
  `archived_at` remain app-schema conventions that the migrator does not enforce.
- Public API is small and documented; types the apps do not need stay `internal`.
- Secrets: the package never logs values. `FileLogger` redacts nothing by itself, so call sites must not pass
  secrets (documented, with a test that the Keychain store's errors contain no value).

## Decisions made (all mine unless marked)

- Observation: new code is `@MainActor @Observable`-friendly, but the package ships no view models, so the
  `ObservableObject` apps are unaffected. Migrating those apps to `@Observable` is a separate task per app.
- Logging: one `FileLogger`, one new file per session in Caches, an "Export Logs" helper that returns the file
  URLs. No analytics or crash SDK.
- Scripts: `ship.sh`, `deploy.sh`, `asc-verify.mjs` and `ExportOptions.plist` stay in the skill template, not in
  the package. A separate follow-up moves spool, hop, busy-hive, fressh and caritos-com onto them.
- Project generation: new apps use XcodeGen (`project.yml` is the source of truth); converting fressh, stark and
  spool is a separate follow-up.

## Adoption

The first plan ends when the package exists, its tests pass, lotus's layout guard allows it and `new-ios-app`
scaffolds an app that depends on it (the skill's full tier proves it builds and tests). No existing app is
changed.

Later, per app and only when the author is working on it. Stark is expected to be first; it has no SQLite, so
it would take `CaritosLogging`, `CaritosSecurity` and `CaritosUI`. The other apps follow as they are touched.
Suggested order of building the products: `CaritosDatabase` and `CaritosSecurity` (largest duplication, clearest
tests), then `CaritosLogging` and `CaritosNetworking`, then `CaritosUI` and `CaritosStorage`.

## Testing

- Each product has unit tests first; the database has an upgrade-from-previous-schema test and a concurrency
  test (borrowed from busy-hive's). The Keychain store is tested behind a protocol fake plus one real-Keychain
  test marked for the app host.
- An app adopting the package keeps its own suite green before and after; the diff of its tests must show
  removals only for the code that moved.
- Verify on device separately and record "confirmed on device" apart from "unit-tested".

## Left to the builder

- Exact API shapes (the survey names the bases, not the signatures), file layout inside each target, and
  the order inside each adoption step.
- Whether `Haptics` and `SettingsRow` belong in the first release or wait for a second user.

## Open questions for the author

None blocking. Answered 2026-10-29: lives in lotus, not a separate repo; named Caritos; no app adopts it yet,
Stark later.
