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
web/                Vite + React + TypeScript app (src/), Playwright (e2e/)
deploy/             systemd units, deploy.sh, restore.sh, pull-backups.sh, smoke.sh, nginx example
scripts/            gen-api.sh, rename.sh and their tests
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
| `make dev` | Go API on :8080 (data under `web/`) plus Vite on :5173; open http://localhost:5173/app/ |

If the full suite is slow, run it in the background and wait for the result.

## Conventions

- Test first (red, green, refactor). Copy and styling changes need no failing test.
- SQLite: UUID text primary keys, Unix-millisecond integer timestamps, soft delete via
  `archived_at`. One owner of the connection (`internal/db`).
- Migrations are numbered `.sql` files embedded in the binary, applied in order inside a
  transaction. Never edit a released migration; add a new one (expand, then contract).
- Never persist absolute file paths; store names relative to `DATA_DIR/storage`.
- Configuration is environment variables only (see `.env.example`); production refuses to start
  without `SESSION_SECRET` and `PUBLIC_ORIGIN`. Secrets never go in the repo.
- Generated code (`*.gen.go`, `schema.d.ts`) is never edited by hand; change `openapi.yaml` and
  run `make api`. API types in the frontend come only from the generated client.
- Go: standard library first, errors wrapped with `%w`, `context.Context` first, `gofmt` and
  `go vet` clean, API responses are typed structs with explicit `json` tags.
- Web: TypeScript `strict`, no `any`, pnpm only (never npm, yarn, Jest or Bun).
- Public pages (`/`, `/faq`, `/privacy`, `/terms`, `/support`) are plain static HTML; keep them
  true to the behavior, including every third-party network call.

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

### Not yet verified

- A real SSH deploy to a server and a real systemd user service.
- The real `rrsync` gate for the pull key and `mv -T` on Linux (only a fake `mv` is tested).
- Browsers other than Chromium.
- The OpenAPI contract against a second client.
- Windows.

### Deferred

Server and HTTP
- Login decoder accepts unknown fields and trailing data; require `Content-Type: application/json`.
- `PUBLIC_ORIGIN` is not normalized (trailing slash or uppercase makes every POST 403); validate in config.
- Zoned IPv6 and ported entries in `X-Forwarded-For` are not stripped; short mapped trusted-proxy prefixes widen to everything.
- 413 responses are plain text while the same-origin 403 is JSON; panicked requests are not request-logged.
- `server.New` silently trusts no proxy on a bad config; its parameters for deps are partly unused.
- `app.New` migrates under `context.Background()` instead of the signal context.
- "listening" is logged before the bind is confirmed; log files created earlier keep their old modes.
- Photo handling: orphan files after a failed old-file delete or a crashed upload (`.upload-*`) are never swept.
- Photo handling: non-ENOENT open errors become an unlogged 404; client disconnect during save logs as 500.
- `PATCH` with a `null` body is a silent no-op; `multipart/mixed` is accepted.
- `openapi.yaml` declares no 500 responses; the login 400 also covers oversized bodies.

Auth
- The dummy bcrypt hash is built on the first unknown-user login, not at startup.
- The old session is not revoked on re-login; expired sessions are not purged on a schedule.
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
- Pre-deploy backups use the default `--keep 14`, so many deploys push out the daily history.
- The `LOAD_ENV` parser in `deploy.sh` differs from systemd's (quotes and CRLF are rejected for the keys it reads).
- `After=network.target` does nothing in a user unit; `SSH_E` is built twice in `deploy.sh`.
- `rrsync` with `REMOTE_DIR=/` is unverified against the real tool; `shellcheck` was not available.

Tests
- Several assertions are weak or probabilistic: the migration concurrency test, transaction-after-expiry, the traversal test, spec path substring check, the unmounted-routes check, and some e2e heading and URL checks.
- Missing cases: `etagMatches` list/weak/`*` forms, HEAD with `If-None-Match`, Content-Length on 404/503, a positive control for the cross-origin and cookie tests, PUT photo cross-user, oversize upload in e2e, file bytes in the upload unit test.
- The boundary guard uses a denylist, exact-match imports and scans `internal/` only; its own unit test is thin.
- Embed tests skip when the app is not built (should fail when `CI` is set).
- e2e: the port is chosen at config load (small race), a signal-killed server is noticed only after the 20 s timeout, `E2E_SKIP_BUILD=1` without a prior build fails confusingly, missing `pnpm` or `go` errors are unfriendly.
- `TestRunDefaultsToServe` mutates the package-level `commands`; a few test names and variables are misleading.
