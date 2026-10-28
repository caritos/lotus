# CLAUDE.md

Guidance for agents working on this template and on projects started from it.

## Purpose

goweb is a starter for a small, self-hosted web product: one Go binary (SQLite, JSON API,
embedded React app and static public pages), a documented systemd-user-service deploy behind an
NGINX reverse proxy, tested backups and restore, and an agent-friendly test setup. The example
feature is notes with an optional photo, behind email + password sign-in.

## Layout and layering

```
web/api/            Go module (go.mod, module path = see go.mod)
  cmd/goweb/        CLI: serve (default), user create, backup, verify-backup, schema-version
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
.claude/            shared settings, post-edit hook, /test and /backup-check commands
```

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
| `make test` | full tier: `go test -race ./...`, `go vet ./...`, Vitest, typecheck, generated-code check, shell script tests |
| `make e2e-install` then `make e2e` | Playwright against the built binary (not part of the other tiers) |
| `make api` | regenerate `models.gen.go` and `schema.d.ts` from `openapi.yaml` |
| `make build` | `pnpm build` (fills the embed directory) then `go build` into `./goweb` |
| `make dev` | Go API on 127.0.0.1:8080 (data under `web/`) plus Vite on :5173; open http://localhost:5173/app/ |

If the full suite is slow, run it in the background and wait for the result.

## Conventions

- Test first (red, green, refactor). Copy and styling changes need no failing test.
- SQLite: UUID text primary keys, Unix-millisecond integer timestamps, soft delete via
  `archived_at`. One owner of the connection (`internal/db`).
- Migrations are numbered `.sql` files embedded in the binary, applied in order inside a
  transaction. Never edit a released migration; add a new one (expand, then contract).
- Never persist absolute file paths; store names relative to `DATA_DIR/storage`.
- Configuration is environment variables only. `.env.example` is the server template
  (`APP_ENV=production`, required `SESSION_SECRET` and `PUBLIC_ORIGIN` left empty); `make dev` sets its
  own environment. Production refuses to start without `SESSION_SECRET` and `PUBLIC_ORIGIN`;
  `PUBLIC_ORIGIN` is validated and normalized; development mode warns when it listens beyond loopback;
  `deploy.sh` refuses a server `.env` that is not `APP_ENV=production` (override: `ALLOW_DEV_DEPLOY=1`).
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
- Generated code (`*.gen.go`, `schema.d.ts`) is never edited by hand; change `openapi.yaml` and
  run `make api`. API types in the frontend come only from the generated client.
- Go: standard library first, errors wrapped with `%w`, `context.Context` first, `gofmt` and
  `go vet` clean, API responses are typed structs with explicit `json` tags.
- Web: TypeScript `strict`, no `any`, pnpm only (never npm, yarn, Jest or Bun).
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
- Backups: `goweb backup` writes daily sets `<stamp>`; `--label NAME` writes `<stamp>-NAME` sets pruned
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
  `cd web/api && printf 'a-long-password\n' | DATA_DIR=.. go run ./cmd/goweb user create you@example.com`.
- Verify: `make test-fast` while working, `make test` before merging, `make e2e` for UI changes.
- Deploy, HTTPS and backups: [docs/deploy.md](docs/deploy.md), [docs/https.md](docs/https.md),
  [docs/backups.md](docs/backups.md). Tests: [docs/testing.md](docs/testing.md).
- Rename the starter for a real project with `scripts/rename.sh <module-path> <name>`.

## Node and pnpm

Node 24 (`.nvmrc`, `engines`). pnpm comes from corepack: `corepack enable`; `package.json`
pins `packageManager`. Commit `pnpm-lock.yaml`. `typescript` is pinned to 5.9.x because
`openapi-typescript` 7 needs the TypeScript 5 compiler API.

## Log

### Done (2026-10-27)

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
  behavior change; `deploy.sh` still uploads `restore.sh` to `~/goweb/restore.sh`.

### Not yet verified

- A real SSH deploy to a server and a real systemd user service.
- The real `rrsync` gate for the pull key and `mv -T` on Linux (only a fake `mv` is tested).
- Browsers other than Chromium.
- The OpenAPI contract against a second client.
- Windows.

### Deferred

Server and HTTP
- Login decoder accepts unknown fields and trailing data; require `Content-Type: application/json`.
- Zoned IPv6 and ported entries in `X-Forwarded-For` are not stripped; short mapped trusted-proxy prefixes widen to everything.
- Panicked requests are not request-logged.
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
