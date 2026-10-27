# goweb: starter template design

Date: 2026-10-27. Status: draft for review.

## Intent

goweb is an open-source starter for Go web apps. A developer clones it and gets a
working single-binary app: a Go backend, a React + TypeScript + Vite frontend embedded
with `go:embed`, and a SQLite database. It deploys to any VPS with no Docker. The
author reuses it as the base for their own new projects; other developers can use it
from GitHub.

Why: every new web project repeats the same setup (embed pipeline, migrations, test
harness, backups, HTTPS docs, agent instructions). goweb does that once, well.

Success: `git clone`, `make dev` runs locally, `make build` produces one binary, and
copying that binary plus a `.env` to a VPS runs the app. Backups and a tested restore
work out of the box.

## Goals

- One self-contained binary serving the JSON API, the React app and static pages.
- SQLite via the pure-Go `modernc.org/sqlite` driver (no cgo), WAL mode.
- Runtime folders under `web/`: `web/db/` (SQLite file), `web/logs/`, `web/storage/`
  (uploads). They are gitignored with a `.gitkeep`, and `DATA_DIR` (default `.`)
  relocates all three on a server.
- A small example app so the template has real flows to test: sign-in plus notes
  (create, edit, delete) with photo upload to `storage/`.
- Unit tests, integration tests and an end-to-end suite (see Testing).
- Automated SQLite backups with a tested restore (see Backups).
- Documented NGINX reverse proxy with TLS certificates and forced HTTPS.
- Agent tooling for Claude Code and tool-neutral instructions for other assistants.

## Non-goals

- No Docker, Kubernetes or other container tooling.
- No Postgres, MySQL or other databases.
- No Cloudflare Tunnel or other tunnel tooling, in code or docs.
- No cloud storage or managed services (no S3). Off-site backup is rsync over SSH.
- No host-specific deploy scripts (no DreamHost, no personal domains or paths).
- No iOS or Android code.
- No email-attachment backups (databases and photos are too large).

## Anti-goals (a failure even if it technically works)

- A fresh clone that does not build, or needs undocumented setup steps.
- A backup that copies a live `.db` file, or a restore that was never tested.
- Personal details of the author in the repo (domains, paths, credentials).
- A template so opinionated that users delete most of it.

## Constraints

- Backend: Go standard library first (`net/http` with `ServeMux`, `log/slog`,
  `database/sql`). Go version is the current stable release at build time, pinned in
  `go.mod`.
- Frontend: Vite + React + TypeScript (`strict`, no `any`), pnpm, Node pinned in
  `.nvmrc` and `engines`, `packageManager` set, `pnpm-lock.yaml` committed.
- Embedded at build time with `go:embed`: the React build, migrations, public pages,
  CSS. Not embedded: the database, logs, uploads, secrets. Config is environment
  variables only, with defaults in code and documented in `.env.example`.
- Build order: `pnpm build` then `go build`. A `.gitkeep` in the embed directory
  keeps a fresh clone compiling.
- Static assets are served with a known `Content-Length`, an `ETag`, `immutable`
  caching for hashed assets and `no-cache` for `index.html`.
- Secrets live in a gitignored `.env`; `.env.example` is committed. The server
  refuses to start in production if a required secret is missing.
- Provide `/healthz`. Set request body size limits and server timeouts.

## Decisions made by the author

- Name: goweb.
- Stack: Go, SQLite, React, TypeScript, Vite, embedded into one binary, run on a VPS.
- Directories `db/`, `logs/`, `storage/`, and a testing directory `tests/`.
- Both unit and integration tests are included.
- Go test placement strategy C: unit tests beside the code, integration tests in
  top-level `tests/`.
- Frontend gets a full end-to-end suite (Playwright), not just a smoke test.
- Example app: sign-in plus notes with photo upload.
- Agent tooling is included.
- Backups: scheduled automatic SQLite backups, `storage/` backed up periodically,
  off-site copy with rsync over SSH.
- HTTPS: NGINX documentation, TLS certificates, redirect to HTTPS. No Cloudflare.
- Audience: the author's own projects and other developers.

## Design

### Layout

The repo may later gain an `ios/` folder (author's decision), so the layout follows the
author's usual one: the frontend at the `web/` root and the Go backend in `web/api/`
with its own `go.mod`.

```
goweb/
  web/                       Vite + React + TS app (package.json, src/, unit tests beside source)
    e2e/                     Playwright suite
    db/ logs/ storage/       runtime dirs, .gitkeep, contents gitignored, ignored by Vite's watcher
    api/                     Go backend, its own go.mod
      cmd/goweb/main.go      entry point, config, graceful shutdown
      internal/
        config/              env-only config
        db/                  Open (DSN, pool), migration runner, migrations/*.sql (embedded)
        server/              router, middleware, static/embed handlers, healthz
        web/app/             Vite build output, embedded (.gitkeep keeps a fresh clone compiling)
        web/pages/ static/   public HTML pages and shared CSS, embedded
        auth/                password hashing, sessions, login throttling
        notes/               example feature: handlers, store
        storage/             upload handling under DATA_DIR/storage
        backup/              snapshot via VACUUM INTO, retention
        testutil/            temp-DB helper, httptest client with cookie jar
      openapi.yaml           API contract (models generated from it)
      tests/                 Go integration tests (black-box, real wiring, temp SQLite)
  deploy/                    systemd unit, nginx example, backup and restore scripts, smoke check
  docs/                      deploy, HTTPS, backups, testing
  .claude/                   shared settings, slash commands, post-edit hook
  AGENTS.md  CLAUDE.md  Makefile  .env.example  .nvmrc  .gitignore  LICENSE
  (ios/ is not included; the layout leaves room for it)
```

### Database

- DSN: foreign keys on, WAL, busy timeout, immediate transactions. Connection pool
  capped; `:memory:` gets one connection.
- Migrations: numbered `.sql` files embedded with `go:embed`, applied in order inside
  a transaction, version recorded in `schema_migrations`. A failed migration stops
  startup. Released migrations are never edited.
- Schema conventions: UUID text primary keys, Unix-ms integer timestamps, soft delete
  with `archived_at`.
- Each migration is tested by upgrading a database pre-populated with data, then
  running `PRAGMA foreign_key_check`.

### Server

- Timeouts on `http.Server`, graceful shutdown on SIGINT and SIGTERM, `umask 077` so
  the database, WAL and backups are owner-only, config from environment only.
- Middleware: security headers, same-origin check, request body limit, request
  logging with `slog` to `logs/app.log` with size-based rotation.
- The React app is mounted under `/app/`. Static public pages (`/`, `/faq`,
  `/privacy`, `/terms`, `/support`) are plain embedded HTML sharing one CSS file.
- Auth for the example app: users table, bcrypt password hashes, server-side
  sessions in a cookie (HttpOnly, SameSite, Secure when behind HTTPS), login
  throttling per user and IP. This is a starting point, not a complete identity system.

### API contract

`api/openapi.yaml` is the source of truth. Go models are generated with
`oapi-codegen` (models only, handwritten handlers); the web app uses
`openapi-typescript` and `openapi-fetch`. Generated code is committed, `make api`
regenerates it, and CI fails if regenerating produces a diff.

### Testing

| Tier | What | Where | Command |
|---|---|---|---|
| Go unit | package logic, handlers with `httptest`, in-memory or temp SQLite | beside code (`foo_test.go`) | `go test -short ./...` |
| Go integration | real server wiring, migrations on populated data, auth flow, upload to `storage/`, backup and restore round trip | `tests/` | `go test -race ./...` plus `go vet ./...` |
| Web unit | components and hooks, Vitest + Testing Library, API mocked with MSW | beside source | `pnpm test` |
| End to end | Playwright against the built binary with a fresh temp database: sign-in, create, edit, delete note, upload photo, sign-out, 404 page | `web/e2e/` | `make e2e` |

`make test-fast` runs the fast tiers, `make test` runs everything except e2e, and
`make e2e` runs the Playwright suite (it downloads browsers, so it is separate).
A test asserts the embedded app and migrations are present in the built binary.

### Backups

- Snapshot with SQLite-aware `VACUUM INTO` (pure Go, no `sqlite3` CLI required on
  the server), never a plain copy of a live `.db`. Triggered by a `goweb backup`
  subcommand run from cron or a systemd timer. Keeps the newest N with a stated
  retention. `storage/` is archived periodically.
- Off-site: a documented pull script rsyncs snapshots over SSH to another machine,
  verifies each with `PRAGMA integrity_check`, and alerts when the newest backup is
  stale or fails verification.
- `restore.sh` verifies integrity, takes a safety copy, stops the service, swaps the
  database, health-checks, and rolls back on failure. It has a `--drill` mode that
  restores into a scratch location. A backup counts only after a drill has passed.

### Deploy and HTTPS

- The service runs as a non-root systemd user service (author's decision), with
  `loginctl enable-linger` enabled and verified by the deploy. The unit lives in
  `~/.config/systemd/user/`; `docs/` describes the system-service variant for hosts
  where the user has root.
- `deploy/` holds a hardened systemd unit (`NoNewPrivileges`, `ProtectSystem=strict`,
  `ReadWritePaths`, `EnvironmentFile`), a generic `deploy.sh` that builds, snapshots
  the database, swaps the binary, health-checks and rolls back on failure, and a
  `smoke.sh` that checks `/healthz`, the home page, the reported build and a 404
  against the public URL.
- `docs/https.md` documents NGINX as a reverse proxy: server block, certificates
  (for example with certbot), HTTP-to-HTTPS redirect, HSTS, proxy headers, and the
  matching `.env` settings (public origin, secure cookies, trusted proxy).

### Agent tooling

- `CLAUDE.md`: layout and layering rules, exact test commands (fast and full tier),
  how to run, verify and deploy, and a dated Done / Not yet verified / Deferred log.
- `AGENTS.md`: short tool-neutral version for Cursor and other assistants.
- `.claude/`: shared `settings.json`, slash commands (`/test`, `/backup-check`), and a
  post-edit hook that runs `go vet` and the fast Go tests.
- A test enforces the import direction between packages (handlers may import stores,
  not the reverse).

## Left to the builder

Package and function names inside the layout, exact middleware ordering, retention
numbers, the Playwright test file breakdown, and the wording of the docs.

## Calls I made (not the author's)

- Layout follows the author's usual one (Go in `web/api/`, frontend at the `web/` root)
  because an `ios/` folder may be added later (author's decision, after I first
  proposed Go at the repo root).
- `go:embed` cannot reach outside the Go module, so Vite builds into
  `web/api/internal/web/app` (`build.outDir`, same as the author's `new-web-app` skill)
  rather than `web/dist`; the author chose to keep `web/api/go.mod` over moving the
  module to `web/` (which would make `go build ./...` walk `node_modules`). Build order is
  still `pnpm build` then `go build`.
- Runtime folders `db/`, `logs/`, `storage/` live under `web/` (author's decision, since
  they belong to the server and the repo may gain `ios/`); `make dev` sets `DATA_DIR` to
  `web/`, the e2e harness uses a temp dir, and the Go server's own default for `DATA_DIR`
  is `.`. Vite's `server.watch.ignored` excludes them so log and WAL writes don't
  trigger rebuilds.
- Include the OpenAPI contract and generated clients, matching the author's usual
  practice.
- Pure-Go `VACUUM INTO` backup via a `goweb backup` subcommand, instead of requiring
  the `sqlite3` CLI.
- Cookie-session auth with per-user accounts for the example app.
- Playwright e2e is separate from `make test` because of the browser download.
- Reuse patterns from the author's school-site project (DB open settings, migration
  runner, test helpers, backup, restore and smoke scripts), stripped of anything
  site-specific.
- Licence: left to the author (MIT suggested).
- Users: no sign-up. Accounts are created with `goweb user create <email>` (password
  read from a prompt or stdin). The e2e suite creates its known user the same way
  against its fresh temp database. Admin UI and password reset are out of scope.
- Dev topology: `make dev` runs Vite on its own port with an API proxy to the Go
  server. The same-origin check compares `Origin` against `PUBLIC_ORIGIN`, which
  `make dev` and the e2e harness set to their own URLs. `SECURE_COOKIES` and
  `TRUSTED_PROXY` are env settings, off by default for local use.
- Build/version: injected with `-ldflags` (version and commit), reported in the
  `/healthz` JSON. `smoke.sh` and `deploy.sh` compare it with what was deployed.
- Photos: one optional photo per note, 5 MB limit, JPEG/PNG/WebP checked by content
  sniffing (not the filename), stored under `storage/` with a generated name, and
  served only through an authenticated handler. The database stores the relative
  filename, never an absolute path. Soft-deleted notes keep their files.
- `storage/` backup: after the database snapshot, the backup copies `storage/` into the
  same timestamped backup set (rsync-style directory copy). `restore.sh` restores both
  and the drill verifies the database and checks that every filename referenced by a
  note exists in the restored `storage/`.
- Renaming: `scripts/rename.sh <module-path> <name>` rewrites the Go module path,
  binary name, env prefix and systemd unit name, with a test; documented in the README.
- CI: ship a GitHub Actions workflow with a fast-tier job, a full-tier job (race, vet,
  `make api` diff check, embed check) and a separate e2e job.
- `/backup-check`: reports the newest backup's age, runs `PRAGMA integrity_check` on it,
  and flags it when older than 3 days.
- Post-edit hook: runs `go vet` and `go test -short` for Go edits, and the type check
  for web edits.
