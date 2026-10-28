---
name: new-ios-app
description: Use when starting a new native iOS (Swift/SwiftUI) app or mobile project, scaffolding an Xcode project, or when an iOS project is missing ship.sh / deploy.sh for TestFlight upload and installing on the iPhone.
---

# New iOS App

## Overview

Every iOS app gets the same skeleton and two scripts from the first commit, so it can be tested on the phone immediately:

- `ios/App/deploy.sh` - build and install on the connected iPhone (fast loop)
- `ios/App/ship.sh` - build, bump build number, upload to TestFlight (no Xcode GUI)

## Scaffold

```bash
bash ~/.claude/skills/new-ios-app/scripts/scaffold.sh <repo-dir> <AppName> <bundle-slug> ["Display Name"]
# e.g. bash .../scaffold.sh ~/src/fressh Fressh fressh "Fressh"
```

Creates (never overwrites an existing `ios/`): `ios/Package.swift` (`<App>Kit`, Swift Testing, `swift test` on Mac), `ios/App/<App>/project.yml` (XcodeGen, bundle `com.caritos.<slug>`, team `3U8L77G9QV`, iOS 17, encryption key false), a thin SwiftUI app, a placeholder alpha-free icon, `ship.sh`, `deploy.sh`, `ExportOptions.plist`, `app.env`, and a project `CLAUDE.md`.

Then: `cd <repo>/ios && swift test`, `ios/App/ship.sh --check`, `ios/App/deploy.sh`.

## One-time setup

| Where | What |
|---|---|
| Once per machine | `~/.appstoreconnect/private_keys/AuthKey_<ID>.p8` (download once) and `~/.appstoreconnect/env` with `API_KEY_ID=` and `API_ISSUER_ID=`. Same key for every app. |
| Once per app, **manual** | Create the app record in App Store Connect for the bundle ID (the API cannot). Do this right after choosing the name, before the plan runs, or the first `ship.sh` fails. |
| Once per app | Replace the placeholder icon (opaque 1024px, no alpha; `~/src/generate-ios-icon`). |

Automatic, by `ship.sh` via `asc-verify.mjs`: creates the Internal TestFlight group with automatic distribution, adds `TESTER_EMAIL` if set, waits for the build to reach `VALID`, and exits non-zero otherwise. Processing at Apple takes roughly 10 to 30 minutes.

## Quick reference

| Command | Does |
|---|---|
| `./deploy.sh` | Install on the only connected iPhone; errors and lists names if several |
| `./deploy.sh "16 Plus"` / `DEVICE=...` | Pick by name substring |
| `./deploy.sh --list` | Show devices and the pick |
| `./ship.sh --check` | Regenerate project, unsigned simulator build, verify credentials; uploads nothing |
| `./ship.sh` | Archive, upload, write the new build number to `project.yml`, then wait for `VALID` (exit 0 = installable from TestFlight) |
| `NEXT_MARKETING_VERSION=2.0 ./ship.sh` | Also change the marketing version |

After `ship.sh`, commit `project.yml` and the regenerated pbxproj. It never submits for review.

## Common mistakes

- Adding or deleting Swift files without `xcodegen generate` (deploy/ship run it, Xcode does not).
- Universal app (`TARGETED_DEVICE_FAMILY "1,2"`) without all four iPad orientations: ASC error 90474.
- `ITSAppUsesNonExemptEncryption: YES`: upload fails ITMS-90592. Keep `NO`.
- Running `ship.sh` over SSH with a locked keychain: `security unlock-keychain ~/Library/Keychains/login.keychain-db`.
- Marketing version string differing from the one created in App Store Connect (`2.0` vs `2.0.0`).
- Copying an older app's `ship.sh` instead of this one: some lack the `/usr/bin` PATH fix or hard-code key IDs.

## Not covered

Backend, website (`<app>.caritos.com`), Settings/legal screen, SQLite and Keychain code: see the project `claude/CLAUDE.md` for where the best existing versions live.
