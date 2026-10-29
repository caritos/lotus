# __DISPLAY__

Native iOS (Swift/SwiftUI). Bundle ID `com.caritos.__SLUG__`.

## Layout
- `ios/Package.swift` - `__APP__Kit`: all testable logic (`swift test`).
- `ios/App/__APP__/` - thin SwiftUI app; `project.yml` (XcodeGen) is the source of truth. Run `xcodegen generate` after changing it or adding/deleting Swift files.
- `ios/App/ship.sh` - build + upload to TestFlight. `ios/App/deploy.sh` - build + install on a connected iPhone.
- `ios/Caritos/` - shared Caritos package (database, logging, networking, Keychain, storage, UI), a read-only snapshot copied from lotus's committed HEAD (`~/src/lotus/ios/Caritos`). Do not edit it here: fix bugs in lotus first (test first, `cd ios/Caritos && swift test` there), commit, then re-copy it into this app.

## Commands
- `swift test` (from `ios/`) - unit tests
- `ios/App/deploy.sh` - run on my phone
- `ios/App/ship.sh` - ship to TestFlight (`--check` to validate without uploading)

## Status
- Done:
- Not yet verified on device:
- Deferred:
