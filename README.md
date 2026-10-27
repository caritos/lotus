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
- `deploy/`: hardened systemd user units, `deploy.sh`, `smoke.sh`, NGINX example
- Tests: Go unit and integration, Vitest, Playwright, shell tests, an import-direction guard, CI
- `CLAUDE.md`, `AGENTS.md` and `.claude/` for AI assistants

## Quick start

You need Go (version in `web/api/go.mod`), Node 24 and pnpm through corepack.

```sh
git clone <this repository> myapp && cd myapp
corepack enable                   # provides the pinned pnpm
(cd web && pnpm install)
make dev                          # Go API on :8080, Vite on :5173
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
cp .env.example .env              # edit it; the server reads real environment variables only
set -a; . ./.env; set +a          # or export the variables however you prefer
APP_ENV=production SESSION_SECRET=$(openssl rand -hex 32) PUBLIC_ORIGIN=https://app.example.com \
  ADDR=127.0.0.1:8080 DATA_DIR=./data ./goweb serve
```

Production refuses to start without `SESSION_SECRET` and `PUBLIC_ORIGIN`. Every setting is
documented in `.env.example`.

## Tests

```sh
make test-fast                    # Go -short, Vitest, typecheck: the inner loop
make test                         # full tier: -race, vet, generated-code check, script tests
make e2e-install && make e2e      # Playwright against the built binary (downloads Chromium)
```

Details in [docs/testing.md](docs/testing.md).

## Deploy in five steps

1. Prepare a Linux server with a normal user, key-only SSH and `loginctl enable-linger`.
2. Create `~/goweb/.env` on the server with `APP_ENV=production`, `SESSION_SECRET`, `PUBLIC_ORIGIN`.
3. Install the systemd user units from `deploy/`.
4. Run `deploy/deploy.sh user@host --check`, then `PUBLIC_URL=https://app.example.com deploy/deploy.sh user@host`.
5. Put NGINX with TLS in front and run `deploy/smoke.sh` against the public URL.

Full walkthrough, rollback and restore: [docs/deploy.md](docs/deploy.md).

## Backups

The binary writes a verified snapshot daily (systemd timer), `deploy/pull-backups.sh` copies them
to another machine and alerts when the newest is stale, and `deploy/restore.sh --drill` proves a
restore. See [docs/backups.md](docs/backups.md).

## HTTPS

NGINX server block, certificates, redirect, HSTS and the matching `.env` settings:
[docs/https.md](docs/https.md).

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
├── deploy/                 systemd units, deploy, restore, pull-backups, smoke scripts, nginx example
├── docs/                   deploy.md, https.md, backups.md, testing.md
├── scripts/                gen-api.sh, rename.sh and their tests
└── web/
    ├── src/                React app (pages, API client, tests)
    ├── e2e/                Playwright tests
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
- [ ] `.env` from `.env.example`, with a real `SESSION_SECRET` and `PUBLIC_ORIGIN`
- [ ] The git remote, and the `app.example.com` examples in `deploy/` and `docs/`
