# Caritos

The shared Swift package for the iOS apps (iOS 17, macOS 14 so `swift test` runs on the Mac).

| Product | Holds |
|---|---|
| `CaritosDatabase` | SQLite connection owner, migration runner, `DatabaseLocation` (links system `sqlite3`) |
| `CaritosSecurity` | Keychain store |
| `CaritosNetworking` | HTTP transport and API errors |
| `CaritosLogging` | File logger |
| `CaritosUI` | Shared SwiftUI components and `Color(hex:)` |
| `CaritosStorage` | File storage helpers |

Rule: a type goes in only when two apps hold a copy.

Run the tests with `cd ios/Caritos && swift test`.
