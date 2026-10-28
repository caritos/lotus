# __DISPLAY__

Native iOS (Swift/SwiftUI). Bundle ID `com.caritos.__SLUG__`.

## Layout
- `ios/Package.swift` - `__APP__Kit`: all testable logic (`swift test`).
- `ios/App/__APP__/` - thin SwiftUI app; `project.yml` (XcodeGen) is the source of truth. Run `xcodegen generate` after changing it or adding/deleting Swift files.
- `ios/App/ship.sh` - build + upload to TestFlight. `ios/App/deploy.sh` - build + install on a connected iPhone.

## Commands
- `swift test` (from `ios/`) - unit tests
- `ios/App/deploy.sh` - run on my phone
- `ios/App/ship.sh` - ship to TestFlight (`--check` to validate without uploading)

## Status
- Done:
- Not yet verified on device:
- Deferred:
