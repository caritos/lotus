# ios/

Reserved for the native iOS app (Swift, SwiftUI, iOS 17+). No app is built here yet.

The shared Caritos Swift package (database, logging, networking, Keychain, storage and common UI) lives in
the starter repo at `ios/Caritos/` (see its README; test it there with `cd ios/Caritos && swift test`). A web app started
from the starter does not carry it: the `new-ios-app` scaffold copies it from the starter's committed `HEAD` into the app.

## Starting it

From the repo root, run the `new-ios-app` skill's scaffold:

```bash
bash ~/.claude/skills/new-ios-app/scripts/scaffold.sh . <AppName> <bundle-slug> "<Display Name>"
```

It creates the `<AppName>Kit` Swift package (`ios/Package.swift`, `ios/Sources/`, `ios/Tests/`), the XcodeGen
app under `ios/App/`, and `ios/App/deploy.sh` (install on the connected iPhone) and `ios/App/ship.sh`
(TestFlight), and copies `ios/Caritos`. It refuses to run only when `ios/Package.swift` or an Xcode project
already exists, so this README does not block it.

## Decisions for later

- **Models:** generate the Swift models from `web/api/openapi.yaml`, as the Go and TypeScript ones are, and
  commit them. Do not hand-write API types.
- **Auth:** the API uses a cookie session (`HttpOnly`, `SameSite=Lax`) and checks `Origin` on mutating
  requests. A native client needs either cookie handling that satisfies that check or a token login
  endpoint. Decide before writing the networking layer.
- **Example screens:** sign in, the notes list and a note with a photo, mirroring the web app.
