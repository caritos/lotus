# CLAUDE.md

Guidance for agents working on this template and on projects started from it.

## Purpose

This starter is for a small, self-hosted web product: one Go binary (SQLite, JSON API,
embedded React app and static public pages), a documented systemd-user-service deploy behind an
NGINX reverse proxy, tested backups and restore, and an agent-friendly test setup. The example
feature is notes with an optional photo, behind email + password sign-in.

## Layout and layering

```
web/api/            Go module (go.mod, module path = see go.mod)
  cmd/app/        CLI: serve (default), user create, backup, verify-backup, schema-version
  internal/
    config/ db/ uid/ version/ apigen/   leaf packages: import no feature package
    auth/ notes/ storage/ backup/ logging/ web/   features and infrastructure
    server/         HTTP wiring and middleware       app/   composition root
    apptest/ testutil/   test-only helpers (never imported by production code)
  tests/            integration tests, embed checks, import-direction guard
  openapi.yaml      the API contract (source of truth)
web/                Vite + React + TypeScript app (src/), Playwright (test/e2e/)
deploy/             files installed on a server only: systemd units, nginx example
scripts/            every repo-level script and its *.test.sh: deploy, smoke, restore, pull-backups, gen-api, rename, build-id, layout
docs/               deploy.md, https.md, backups.md, testing.md (superpowers/ holds design history)
dist/              compiled binary from `make build` (ignored); the frontend build is NOT here, see below
ios/                reserved for the native iOS app; only a README so far (scaffold it with the new-ios-app skill)
.claude/            shared settings, post-edit hook, /test and /backup-check commands
.claude/skills/     the new-web-app and new-ios-app skills; excluded from what a new app copies, ignored by rename.sh and layout.test.sh
```

`dist/` holds only the compiled Go binary. Vite's output (`pnpm build`) goes to
`web/api/internal/web/app/` (ignored) instead of the usual `dist/`, because `go:embed` can only embed
files inside the Go module.

Import-direction rules (enforced by `web/api/tests/boundary_test.go`):

- Handlers and stores (`notes`, `auth`, `storage`, `backup`, `logging`, `web`) never import
  `server`, `app` or `apptest`; only `server`, `app` and `cmd` compose features.
- `db`, `config`, `uid`, `version` and `apigen` are leaf packages: they import no feature package.
- `auth` does not import `notes`; `notes` gets its `*sql.DB` injected and does not import `db`.
- `web` (the embedded UI) is wired in by `server` only.

## Commands

| Command | What |
|---|---|
| `make test-fast` | fast tier: `go test -short ./...`, `pnpm test`, `pnpm typecheck` |
| `make test-skills` | fast tier of the skill tests (`.claude/skills/new-web-app/tests/run.sh --fast`; the full tier is `bash .claude/skills/new-web-app/tests/run.sh`, which scaffolds a real app from the committed `HEAD`, see `docs/testing.md`) |
| `make test` | full tier: `go test -race ./...`, `go vet ./...`, Vitest, typecheck, generated-code check, shell script tests |
| `make e2e-install` then `make e2e` | Playwright against the built binary (not part of the other tiers) |
| `make api` | regenerate `models.gen.go` and `schema.d.ts` from `openapi.yaml` |
| `make build` | `pnpm build` (fills the embed directory) then `go build` into `./dist/app` |
| `make dev` | Go API on 127.0.0.1:8080 (data under `web/`) plus Vite on :5173; open http://localhost:5173/app/ |

If the full suite is slow, run it in the background and wait for the result.

## Conventions

- Test first (red, green, refactor). Copy and styling changes need no failing test.
- SQLite: UUID text primary keys, Unix-millisecond integer timestamps, soft delete via
  `archived_at`. One owner of the connection (`internal/db`).
- Migrations are numbered `.sql` files embedded in the binary, applied in order inside a
  transaction. Never edit a released migration; add a new one (expand, then contract). The runner
  enforces this: it records each file's sha256 in `schema_migrations.checksum` (over the exact bytes, so
  whitespace and line endings count; `.gitattributes` keeps `*.sql` as `-text`) and refuses to run (naming the
  file, applying nothing further) when an applied file's bytes change. Files must be named
  `NNNN_description.sql` (`^[0-9]{4}_[a-z0-9_]+\.sql$`) with unique `NNNN`; gaps are fine.
- Never persist absolute file paths; store names relative to `DATA_DIR/storage`.
- Configuration is environment variables only. `.env.example` is the server template
  (`APP_ENV=production`, required `SESSION_SECRET` and `PUBLIC_ORIGIN` left empty); `make dev` sets its
  own environment. Production refuses to start without `SESSION_SECRET` and `PUBLIC_ORIGIN`;
  `PUBLIC_ORIGIN` is validated and normalized; development mode warns when it listens beyond loopback;
  `deploy.sh` refuses a server `.env` that is not `APP_ENV=production` (override: `ALLOW_DEV_DEPLOY=1`).
  `deploy.sh` also refuses a port already held by another service, and with `EXPECT_PUBLIC_LISTENER=1`
  a loopback `ADDR` or a missing public listener (`ss`); see `docs/deploy.md`.
  `deploy.sh` runs a test gate (`go vet`, `go test -short`, `pnpm test`, `pnpm typecheck`) and a Node-major
  check against `.nvmrc` before anything changes (`SKIP_TESTS=1` skips only the tests, not the Node check), and
  warns when `${SERVICE}-backup.timer` is not enabled, or its state cannot be determined, on the server
  (`REQUIRE_BACKUP_TIMER=1` refuses both).
  Secrets never go in the repo.
- Embed everything static with `go:embed` so a release is one binary plus the server `.env`: migrations,
  the React build, public pages, CSS, fonts (subfolders of `static/` are served at `/static/<path>`), icons,
  seed data, default config and email or text templates. Put seed data and templates in a `data/` or
  `templates/` folder inside the package that uses them (`//go:embed data/*`), never read them from disk at
  runtime, and have tests use the embedded `fs.FS`. Never embed anything written at runtime (the database,
  logs and uploads live under `DATA_DIR`), secrets or large media. Every 200 from `internal/web` carries an
  `ETag` and a matching `If-None-Match` is a bodiless 304, because embedded files have no mod time.
- A new endpoint needs three things, enforced by `web/api/tests/guardrails_test.go` (details in
  `docs/testing.md`): a literal `"METHOD /path"` route pattern, an `operationId` in `openapi.yaml`, and an
  integration test marked `// covers: <operationId>` (copy `notes_flow_test.go`).
- A new endpoint is private by default: `server.New` mounts everything under `/api/` behind `auth.Middleware` +
  `auth.Require`, so mount new routes inside that private mux (not directly on the top-level mux) and a signed-out
  request gets 401 (an unknown `/api/` path is 401 signed out, 404 signed in). A public endpoint must be added to
  the one allowlist, `publicRoutes` in `web/api/tests/guardrails_test.go`, WITH a reason, registered explicitly in
  `server.New`, and marked `security: []` in `openapi.yaml`; `TestAPIIsPrivateByDefault` and
  `TestPublicAllowlistMatchesTheSpec` fail otherwise.
- Money is stored as integer cents (no floats); the example schema has no money column.
- Generated code (`*.gen.go`, `schema.d.ts`) is never edited by hand; change `openapi.yaml` and
  run `make api`. API types in the frontend come only from the generated client.
- Go: standard library first, errors wrapped with `%w`, `context.Context` first, `gofmt` and
  `go vet` clean, API responses are typed structs with explicit `json` tags.
- Web: TypeScript `strict`, no `any`, pnpm only (never npm, yarn, Jest or Bun).
- Middleware chain in `server.New` (outermost first): TrustedProxy, RequestID, RequestLog, Recover,
  SecurityHeaders, SameOrigin, BodyLimit. Every response carries `X-Request-Id` (an inbound one matching
  `^[A-Za-z0-9._-]{1,64}$` is reused, else 16 hex characters); the request log line and the panic log have
  `request_id`. A handler panic is a 500 `{"error":"internal error"}` (no panic value to the client; value and
  stack logged at Error), only logged when the response had already started, and `http.ErrAbortHandler` is
  re-panicked. Tests pin the order (`TestNewAppliesChain`, `TestWrapPanicOrder`).
- HTTPS and HSTS belong to the reverse proxy: the app never sends `Strict-Transport-Security`
  (see `docs/https.md` for the staged max-age rollout). Do not add it back in the middleware.
- Public pages (`/`, `/faq`, `/privacy`, `/terms`, `/support`) are plain static HTML; keep them
  true to the behavior, including every third-party network call.
- Build id: every HTML page the app serves (public pages, the 404 and "app not built" pages, the React
  app) has a footer with `Build YYYYMMDD-<short commit>` (UTC build date; `-dirty` when tracked files are
  modified; `unknown` as the commit outside git). `/healthz` reports it as `build_id`. The id is set only by
  `scripts/build-id.sh` passed as `-ldflags -X <module>/internal/version.BuildID=...` (`make build`, `make dev`,
  `scripts/deploy.sh`, `web/test/e2e/global-setup.ts`); never hard-code it. The web package substitutes it once at
  startup (before ETags and lengths): new HTML pages in `internal/web/pages/` must contain the literal
  `@@BUILD_ID@@` exactly once inside a `site-footer` (a test enforces it); the React app reads it from the
  `build-id` meta tag in `web/index.html` (`__BUILD_ID__`). `smoke.sh` checks it after every deploy.
- Every subcommand runs under umask 077 (set in `run`), so the database, WAL/SHM, logs, uploads and
  backups are owner-only whichever command creates them.
- Backups: `app backup` writes daily sets `<stamp>`; `--label NAME` writes `<stamp>-NAME` sets pruned
  only against the same label (deploys use `--label predeploy --keep 5`). `pre-restore-*` copies are never
  pruned automatically. `pull-backups.sh` copies daily sets only.
- Housekeeping: `serve` purges expired sessions at start and hourly (`app.RunMaintenance`); `app.New`
  removes `storage/.upload-*` temp files older than an hour.

## Known properties

- Sign-in lockout is a denial-of-service lever, by design of a simple in-memory throttle: 20 failed
  sign-ins for one email lock that account for 15 minutes, from anywhere; and with `TRUSTED_PROXY`
  empty behind a proxy, 50 failures from anyone lock every user behind the proxy's address for
  15 minutes. Set `TRUSTED_PROXY` correctly; a restart clears the counters. See `docs/deploy.md`.
- The deploy health check probes `127.0.0.1:<ADDR port>`, so `ADDR` must be loopback, `0.0.0.0` or
  `:<port>`, never a single non-loopback address.

## Run, verify, deploy

- Run locally: `make dev`, create a user with
  `cd web/api && printf 'a-long-password\n' | DATA_DIR=.. go run ./cmd/app user create you@example.com`.
- Verify: `make test-fast` while working, `make test` before merging, `make e2e` for UI changes.
- Deploy, HTTPS and backups: [docs/deploy.md](docs/deploy.md), [docs/https.md](docs/https.md),
  [docs/backups.md](docs/backups.md). Tests: [docs/testing.md](docs/testing.md).
- Rename the starter for a real project with `scripts/rename.sh <module-path> <name>`. The shipped name `app`
  is also a Go package (`internal/app`), the embed directory (`internal/web/app`), the `/app/` URL mount and
  the `APP_` env prefix, so the script never replaces the bare word: it reads the current module path and name
  from `web/api/go.mod` and `web/api/cmd/`, and replaces the name only in project-name contexts (module path,
  `cmd/<name>`, `dist/<name>`, `<name>_session`, `<name>.db`, unit names, `~/<name>`, `<NAME>_BIN`, page title
  and `<h1>`; the full list is in the header of the script). Prose is not rewritten; `scripts/rename.test.sh`
  renames to several names and back (byte-identical) and shows the generic uses are untouched.
- A fresh checkout is called `app`, which is generic: the server and Mac names built from it (`~/<name>`,
  `<name>.service`, `<name>.db`, `com.<name>.backup-pull`) can clash with another app. Run `scripts/rename.sh` before a real deployment. That is the only supported route;
  overriding `REMOTE_BASE`/`SERVICE` alone leaves `restore.sh`, the unit files and the Mac agent generic.
  `rename.sh` rejects a name that is reserved (directory and variable words such as `web`, `data`; the `RESERVED`
  list is only a fast pre-filter) or that already occurs in the tree in a context it rewrites (checked at run
  time: renaming back would not be exact); `rename.sh --check <module-path> <name>` runs these checks only.

## Node and pnpm

Node 24 (`.nvmrc`, `engines`). pnpm comes from corepack: `corepack enable`; `package.json`
pins `packageManager`. Commit `pnpm-lock.yaml`. `typescript` is pinned to 5.9.x because
`openapi-typescript` 7 needs the TypeScript 5 compiler API.

## Log

### Done (2026-10-27)

- Skills in the repo (2026-10-28): `new-web-app` and `new-ios-app` live in `.claude/skills/` and the wrapper's default starter is the repo it lives in (`GOWEB_DIR` still overrides). The wrapper leaves `.claude/skills/` out of a new app, validates the slug with `scripts/rename.sh --check`, protects generic prose "app" in the pages while the display name replaces the title, brand link, first h1 and "What is" heading, and its goweb L3 warning is gone (the layout guard has a host mode). `scripts/rename.sh`, `scripts/layout.test.sh` and `scripts/rename.test.sh` ignore `.claude/skills/` like `docs/superpowers/`. `make test-skills` is part of `make test`.
- Follow-ups batch (2026-10-27): `deploy.sh` separates timer enabled / not enabled / could not determine, runs
  its test gate without the caller's `GOOS`/`GOARCH`, skips the Node check for a non-numeric `.nvmrc` and
  compares majors only, and reports a missing `ss` or an ssh failure after the restart as such; the deploy
  fakes now record unit names, working directories and can inject ssh failures. `install-backup-agent.sh`
  waits for `bootout`, retries `bootstrap`, says "nothing installed" and has `--dry-run`; `deploy.test.sh`
  prints `SKIPPED: n`. Migrations: file-name and duplicate-version validation, byte-exact checksum documented,
  `.gitattributes` `*.sql -text`, concurrent legacy upgrade test. Panic log record pinned (stack names the
  function, fields on the right records); `Wrap` documented. Layout guard self-tests prove the `deploy/` check
  fired. Real launchd load is still not verified on a Mac.
- Follow-ups part 2 (2026-10-27): `/api/` is default-deny (public login, logout and me registered explicitly,
  everything else behind `auth.Require`; guard tests and the single `publicRoutes` allowlist); `deploy.sh` runs
  `pnpm install --frozen-lockfile` before the gate and the build (gate's `go test -short` stays without `-race`);
  `scripts/layout.test.sh` has a host mode keyed on the wrapper's marker file (its name is the wrapper's contract, not the project name; starter-only checks skipped, log found in
  `CLAUDE.md` or `web/CLAUDE.md`); money-in-cents convention.
- Panic recovery and request id: `RequestID` and `Recover` middleware (order above); a panicking request
  is now a JSON 500, request-logged with its id, and the server keeps serving. `server.Wrap` exposes the chain
  so tests can put a panicking handler inside it.
- Migration checksums: `schema_migrations.checksum` (sha256 of the file); an edited applied migration stops
  `Migrate` with "add a new migration instead". Databases from before this change get the column added and
  backfilled from the files embedded in the binary at first run, so their earlier history cannot be verified.
- `deploy.sh`: port-owner check (always) and optional `EXPECT_PUBLIC_LISTENER=1` public-listener checks,
  with shell tests using a fake `ss`.
- `deploy.sh`: test gate before the lock, build and upload (`go vet`, `go test -short` in `web/api`, `pnpm test`,
  `pnpm typecheck` in `web/`; `SKIP_TESTS=1` skips the tests only; not run by `--check`), Node major checked against `.nvmrc`
  unless `SKIP_WEB_BUILD=1`, and a preflight on `${SERVICE}-backup.timer` (warning, or refusal with
  `REQUIRE_BACKUP_TIMER=1`; also in `--check`). Shell tests use fake `go`, `pnpm`, `node` and `systemctl`.
- `scripts/install-backup-agent.sh`: launchd agent for the Mac backup pull (daily 03:30, settings in
  `~/.config/app/backup-pull.env` from `scripts/backup-pull.env.example`, `--uninstall`); shell tests use a fake
  `launchctl`. Real launchd load: not yet verified on a Mac.

- Go server: config, SQLite open and embedded migrations, `/healthz`, security middleware,
  trusted-proxy handling, request log with a rotating file logger.
- Auth: sessions, login throttle, `user create` command.
- Notes API with photo upload and storage; OpenAPI contract with generated Go and TypeScript models.
- React + TypeScript frontend (sign-in, notes, photo upload), embedded with `go:embed` under `/app/`,
  plus embedded public pages.
- Backups (`backup`, `verify-backup`), `restore.sh` with a drill mode, `pull-backups.sh`.
- Deploy: `deploy.sh`, `smoke.sh`, systemd user units and timer, NGINX and HTTPS docs.
- Tests: unit, integration (with an import-direction guard and embed checks), Vitest, Playwright e2e,
  shell tests for deploy, generator, hook and rename scripts.
- Agent tooling: this file, `AGENTS.md`, `.claude/` settings, hook and commands, CI workflow,
  `scripts/rename.sh`.
- Backups verified (restore tested): drill passes in the automated tests on 2026-10-27; real server drill: not yet
- Final-review fix pass (2026-10-27): the app no longer sends HSTS (the proxy owns it); `.env.example` is
  the production server template and `deploy.sh` refuses a non-production server `.env`
  (`ALLOW_DEV_DEPLOY=1` overrides); `serve` warns when development mode listens beyond loopback;
  `PUBLIC_ORIGIN` is validated and normalized; umask 077 for every subcommand; labeled backups
  (`--label`, pre-deploy sets kept separately, 5 newest); expired sessions purged at start and hourly;
  stale upload temp files swept at start; 403/413 documented in `openapi.yaml` and 413 is JSON;
  unreadable photo files are logged 500s; middleware order and the proxy-to-throttle seam are pinned by
  tests; CI catches untracked generated files and fails (not skips) the embed check without a build.
- Retro from the skills audit (2026-10-27): `/static/` now serves nested files (fonts) from the embedded
  tree with explicit `font/woff2` and `font/woff` types; added the deferred `etagMatches` list, weak and `*`
  cases, HEAD with `If-None-Match`, and Content-Length without ETag on 404 and 503; `make test` fails on
  files that are not gofmt-clean; the embed rule above. The same rule and fixes went into the
  `new-backend-server` and `new-web-app` skills.
- Endpoint guard rails (2026-10-27): the spec and the registered routes must match, and every
  `operationId` must be claimed by a `// covers:` comment on an integration test. Adding them found two
  untested operations (`getNote` and `updateNote` had no successful-path integration test); added
  `TestNoteGetAndUpdate`.
- Build id in every page footer (2026-10-27): `scripts/build-id.sh` (+ `build-id.test.sh`), `version.BuildID`
  via `-ldflags` in the Makefile, `deploy.sh` and the e2e harness, `build_id` in `/healthz` and `openapi.yaml`,
  footer placeholder substitution in `internal/web` (static pages, 404, 503, the app's `index.html`), React
  `Footer`, Playwright spec, and `smoke.sh`/`deploy.sh` checks (`EXPECTED_BUILD_ID`).
- Layout cleanup (2026-10-27): one `scripts/` for every repo-level script and its `*.test.sh` (`deploy.sh`,
  `smoke.sh`, `restore.sh`, `pull-backups.sh`, `deploy.test.sh` moved from `deploy/`, which now holds only files
  installed on a server); Playwright moved from `web/e2e/` to `web/test/e2e/` (+ `web/test/README.md`);
  `scripts/layout.test.sh` guards both and is part of `make test-scripts` and the CI full job. Pure moves, no
  behavior change; `deploy.sh` still uploads `restore.sh` to `~/app/restore.sh`.
- `ios/` reserved (2026-10-27): the kit is for the author's own apps, so a native iOS app belongs in it. Only
  `ios/README.md` exists for now (git keeps no empty directories); it does not block the `new-ios-app` scaffold,
  which refuses only when `ios/Package.swift` or an Xcode project exists. `scripts/layout.test.sh` keeps `ios/` tracked.
- Binary output and rename (2026-10-27): `make build` writes `dist/<name>` (ignored; the frontend still builds
  into `web/api/internal/web/app/` because `go:embed` needs it inside the module); the project was renamed
  from its original working name to `app` with `scripts/rename.sh`, which was then rewritten to read the current names from the
  repository and to replace the name only in project-name contexts (renaming away from the generic word `app`
  must not touch `internal/app`, `internal/web/app`, `/app/` or `APP_ENV`). `smoke.sh` now requires the name as
  a whole word in the home page's `<title>` or first `<h1>`. `docs/superpowers/` is historical and keeps the
  original working name; the author's checkout directory (still named after it) is not renamed.
- Layout guard in a renamed app (2026-10-27): `scripts/layout.test.sh` compared the `deploy/` file list in
  pre-rename `ls` order, so every renamed app failed it. It now compares sorted sets (self-tests prove an extra
  and a missing file still fail), and `scripts/rename.test.sh` runs the guard in its renamed copy.

### Not yet verified

- A real SSH deploy to a server and a real systemd user service.
- The real `rrsync` gate for the pull key and `mv -T` on Linux (only a fake `mv` is tested).
- Browsers other than Chromium.
- The OpenAPI contract against a second client.
- Windows.

### Deferred

iOS (`ios/` is only a placeholder)
- Scaffold the app with the `new-ios-app` skill and wire its `ship.sh` / `deploy.sh`.
- Generate the Swift models from `web/api/openapi.yaml` and commit them; no hand-written API types.
- Decide native auth: the API uses a cookie session and checks `Origin` on mutating requests, so a native client
  needs matching cookie handling or a token login endpoint.
- Example screens: sign in, notes list, a note with a photo.
- `scripts/rename.sh` does not know about the bundle id, `project.yml` or Kit names; extend it when the app exists.

Server and HTTP
- Login decoder accepts unknown fields and trailing data; require `Content-Type: application/json`.
- Zoned IPv6 and ported entries in `X-Forwarded-For` are not stripped; short mapped trusted-proxy prefixes widen to everything.
- `server.New` silently trusts no proxy on a bad config; its parameters for deps are partly unused.
- `app.New` migrates under `context.Background()` instead of the signal context.
- "listening" is logged before the bind is confirmed; log files created earlier keep their old modes.
- Photo handling: an orphan photo file left after a failed old-file delete is never swept.
- Photo handling: a client disconnect during save logs as 500.
- `PATCH` with a `null` body is a silent no-op; `multipart/mixed` is accepted.
- `openapi.yaml` declares no 500 responses.
- `PUBLIC_ORIGIN` with a non-ASCII (IDN) host is lowercased but not converted to punycode, which is what browsers send; write it in punycode.

Auth
- The dummy bcrypt hash is built on the first unknown-user login, not at startup.
- The old session is not revoked on re-login.
- `user create` echoes the password on a TTY (piping is the documented way); duplicate email is detected by error text.

Frontend
- Rejected fetches leave "Loading..." with an unhandled rejection in the session, list and edit views.
- `NoteEdit` shows a stale note when the id changes; `RequireAuth` drops the requested path on redirect.
- `make dev` only works from exactly http://localhost:5173 (127.0.0.1 fails the same-origin check).
- The test setup swaps FormData/File/Request for a jsdom quirk; remove it when jsdom allows.
- `openapi-typescript --binary` would type the photo as a Blob and remove the upload serializer workaround.
- `clean-app.mjs` could guard that the directory is named `app`.

Backups, restore and deploy
- Pull script: `mv` results are unchecked, `DEST` of `/` or `$HOME` is not rejected, stale partials with a newer stamp stay forever.
- Pull script: `KEEP` below server retention causes re-pull churn; `pre-restore-*` and `DEST/failed` are never pruned.
- Pull script: a FIFO swapped in before open can block; ssh path, `osascript` and a real systemd are untested.
- The `LOAD_ENV` parser in `deploy.sh` differs from systemd's (quotes and CRLF are rejected for the keys it reads: `APP_ENV`, `DATA_DIR`, `ADDR`).
- The pre-deploy backup runs the active release's `backup --label`; a fork deploying over a binary built before `--label` existed must take that first backup by hand.
- `After=network.target` does nothing in a user unit; `SSH_E` is built twice in `deploy.sh`.
- `rrsync` with `REMOTE_DIR=/` is unverified against the real tool; `shellcheck` was not available.

Tests
- Several assertions are weak or probabilistic: the migration concurrency test, transaction-after-expiry, the traversal test, spec path substring check, the unmounted-routes check, and some e2e heading and URL checks.
- Missing cases: a positive control for the cross-origin and cookie tests, PUT photo cross-user, oversize upload in e2e, file bytes in the upload unit test.
- The boundary guard uses a denylist, exact-match imports and scans `internal/` only; its own unit test is thin.
- e2e: the port is chosen at config load (small race), a signal-killed server is noticed only after the 20 s timeout, `E2E_SKIP_BUILD=1` without a prior build fails confusingly, missing `pnpm` or `go` errors are unfriendly.
- `TestRunDefaultsToServe` mutates the package-level `commands`; a few test names and variables are misleading.
- The maintenance goroutine's wiring in `serve` (start, cancel, wait before close) has no serve-level test; `app.RunMaintenance` itself is tested.
