# goweb

A starter for a small, self-hosted web product. One Go binary serves a JSON API backed by
SQLite, a React + TypeScript app and static public pages (home, FAQ, privacy, terms, support).
It comes with automated backups and a tested restore, a deploy script for a plain Linux server,
HTTPS documentation, a layered test suite and tooling for AI coding assistants. The example
feature is notes with an optional photo, behind email + password sign-in.

## What you get

- Go (standard library first), SQLite via a pure-Go driver (no cgo), numbered embedded migrations
- Spec-first API: `web/api/openapi.yaml` generates the Go models and the TypeScript client types
- Vite + React + TypeScript (`strict`) with pnpm, embedded in the binary and served under `/app/`
- Sessions, login throttling, security headers, same-origin checks, request log with rotation
- Daily SQLite-aware backups, off-site pull script, restore script with a drill mode
- A build id (`YYYYMMDD-<short commit>`, UTC date) in the footer of every page and in `/healthz`,
  made by `scripts/build-id.sh`; it tells you which build is live (`-dirty` marks a modified tree)
- `deploy/`: hardened systemd user units and the NGINX example; `scripts/deploy.sh` and `scripts/smoke.sh` deploy and check them
- Tests: Go unit and integration, Vitest, Playwright, shell tests, an import-direction guard, CI
- `CLAUDE.md`, `AGENTS.md` and `.claude/` for AI assistants

## Quick start

You need Go (version in `web/api/go.mod`), Node 24 and pnpm through corepack.

```sh
git clone <this repository> myapp && cd myapp
corepack enable                   # provides the pinned pnpm
(cd web && pnpm install)
make dev                          # Go API on 127.0.0.1:8080, Vite on :5173 (sets its own env)
```

Create a user (the password is read from stdin) in another terminal, then open
http://localhost:5173/app/ and sign in:

```sh
cd web/api
printf 'a-long-password\n' | DATA_DIR=.. go run ./cmd/goweb user create you@example.com
```

Open http://localhost:5173 exactly as written (not 127.0.0.1): the same-origin check compares it.
Development data lives under `web/` (`db/`, `logs/`, `storage/`, all gitignored).

## Build and run

```sh
make build                        # pnpm build, then go build -> ./goweb
# try the binary locally (development mode, loopback only, data under ./data):
ADDR=127.0.0.1:8080 PUBLIC_ORIGIN=http://127.0.0.1:8080 DATA_DIR=./data ./goweb serve
```

Configuration is environment variables only. `.env.example` is the template for the **server's**
`.env` (it says `APP_ENV=production` and leaves the required `SESSION_SECRET` and `PUBLIC_ORIGIN`
empty); local development does not use it, because `make dev` sets its own environment.
Production refuses to start without `SESSION_SECRET` and `PUBLIC_ORIGIN`, and development mode
logs a warning when it listens on anything but loopback.

## Build id

Every HTML page the app serves (the public pages, the 404 page and the React app) shows
`Build YYYYMMDD-<short commit>` in its footer, for example `Build 20261027-37434d8`, and
`/healthz` reports the same value as `build_id`. The date is the UTC build date and the commit is
the 7-character `git rev-parse --short=7 HEAD`; `-dirty` is appended when tracked files had
uncommitted changes, and the commit part is `unknown` outside git. `scripts/build-id.sh` prints it;
`make build`, `make dev`, `scripts/deploy.sh` and the e2e harness pass it to the binary with
`-ldflags`. A plain `go build` shows `00000000-unknown`; the Vite dev server shows `Build dev`.

```sh
scripts/build-id.sh                      # 20261027-37434d8
curl -s https://app.example.com/ | grep -o 'Build [0-9a-z-]*'
```

## Tests

```sh
make test-fast                    # Go -short, Vitest, typecheck: the inner loop
make test                         # full tier: -race, vet, generated-code check, script tests
make e2e-install && make e2e      # Playwright against the built binary (downloads Chromium)
```

Details in [docs/testing.md](docs/testing.md).

## Deploy in five steps

1. Prepare a Linux server with a normal user, key-only SSH and `loginctl enable-linger`.
2. Create `~/goweb/.env` on the server from `.env.example` (`APP_ENV=production`; fill in
   `SESSION_SECRET` and `PUBLIC_ORIGIN`). `deploy.sh` refuses a server `.env` that is not production.
3. Install the systemd user units from `deploy/`.
4. Run `scripts/deploy.sh user@host --check`, then `PUBLIC_URL=https://app.example.com scripts/deploy.sh user@host`.
5. Put NGINX with TLS in front and run `scripts/smoke.sh` against the public URL.

Full walkthrough, rollback and restore: [docs/deploy.md](docs/deploy.md).

## Backups

The binary writes a verified snapshot daily (systemd timer), `scripts/pull-backups.sh` copies them
to another machine and alerts when the newest is stale, and `scripts/restore.sh --drill` proves a
restore. See [docs/backups.md](docs/backups.md).

## HTTPS

NGINX server block, certificates, redirect, HSTS and the matching `.env` settings:
[docs/https.md](docs/https.md). The proxy sets HSTS; the app never sends it, so the proxy's staged
rollout is the one browsers see.

## Rename it

```sh
scripts/rename.sh github.com/you/myapp myapp
```

This rewrites the Go module path, the binary, cookie, unit and database names, and renames the
files that carry the old name. Run it on a clean git tree; `scripts/rename.test.sh` covers it.

## Layout

```
.
├── CLAUDE.md  AGENTS.md  Makefile  .env.example  .nvmrc
├── .claude/                settings.json, hooks/post-edit.sh, commands/
├── .github/workflows/      ci.yml (fast, full, e2e)
├── deploy/                 files installed on a server: systemd units, nginx example
├── docs/                   deploy.md, https.md, backups.md, testing.md
├── scripts/                deploy, smoke, restore, pull-backups, gen-api, rename, build-id and their *.test.sh
└── web/
    ├── src/                React app (pages, API client, tests)
    ├── test/               e2e/ (Playwright tests), README.md
    └── api/                Go module
        ├── cmd/goweb/      command line
        ├── internal/       config, db, auth, notes, storage, backup, server, app, web, ...
        ├── tests/          integration tests
        └── openapi.yaml    API contract
```

## Agent tooling

[CLAUDE.md](CLAUDE.md) holds the layout rules, exact commands, conventions and a dated log.
[AGENTS.md](AGENTS.md) is the short tool-neutral version. `.claude/` has shared permissions, a
post-edit hook (Go edits run `go vet` and `go test -short` for the package; web edits run
`tsc`), and the `/test` and `/backup-check` commands.

## Replace these placeholders

- [ ] Public page copy in `web/api/internal/web/pages/` (home, FAQ, privacy, terms, support)
- [ ] The support email `support@example.com` in those pages
- [ ] This README's title and text
- [ ] A `LICENSE` file: none is included, choose one yourself
- [ ] The server's `.env` from `.env.example`, with a real `SESSION_SECRET` and `PUBLIC_ORIGIN`
- [ ] The git remote, and the `app.example.com` examples in `deploy/` and `docs/`
