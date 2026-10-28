# app

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
  made by `web/scripts/build-id.sh`; it tells you which build is live (`-dirty` marks a modified tree)
- `web/deploy/`: hardened systemd user units and the NGINX example; `web/scripts/deploy.sh` and `web/scripts/smoke.sh` deploy and check them
- `ios/`: reserved for the native iOS app; not built yet (see `ios/README.md`)
- Tests: Go unit and integration, Vitest, Playwright, shell tests, an import-direction guard, CI
- `CLAUDE.md`, `AGENTS.md` and `.claude/` for AI assistants

## Quick start

You need Go (version in `web/api/go.mod`), Node 24 and pnpm through corepack.

```sh
git clone <this repository> myapp && cd myapp
corepack enable                   # provides the pinned pnpm
(cd web && pnpm install)
make -C web dev                    # Go API on 127.0.0.1:8080, Vite on :5173 (sets its own env)
```

Create a user (the password is read from stdin) in another terminal, then open
http://localhost:5173/app/ and sign in:

```sh
cd web/api
printf 'a-long-password\n' | DATA_DIR=.. go run ./cmd/app user create you@example.com
```

Open http://localhost:5173 exactly as written (not 127.0.0.1): the same-origin check compares it.
Development data lives under `web/` (`db/`, `logs/`, `storage/`, all gitignored).

## Build and run

```sh
make -C web build                  # pnpm build, then go build -> web/dist/app
# try the binary locally (development mode, loopback only, data under ./data):
ADDR=127.0.0.1:8080 PUBLIC_ORIGIN=http://127.0.0.1:8080 DATA_DIR=./data web/dist/app serve
```

Configuration is environment variables only. `web/deploy/.env.example` is the template for the **server's**
`.env` (it says `APP_ENV=production` and leaves the required `SESSION_SECRET` and `PUBLIC_ORIGIN`
empty); local development does not use it, because `make -C web dev` sets its own environment.
Production refuses to start without `SESSION_SECRET` and `PUBLIC_ORIGIN`, and development mode
logs a warning when it listens on anything but loopback.

## Build id

Every HTML page the app serves (the public pages, the 404 page and the React app) shows
`Build YYYYMMDD-<short commit>` in its footer, for example `Build 20261027-37434d8`, and
`/healthz` reports the same value as `build_id`. The date is the UTC build date and the commit is
the 7-character `git rev-parse --short=7 HEAD`; `-dirty` is appended when tracked files had
uncommitted changes, and the commit part is `unknown` outside git. `web/scripts/build-id.sh` prints it;
`make -C web build`, `make -C web dev`, `web/scripts/deploy.sh` and the e2e harness pass it to the binary with
`-ldflags`. A plain `go build` shows `00000000-unknown`; the Vite dev server shows `Build dev`.

```sh
web/scripts/build-id.sh                      # 20261027-37434d8
curl -s https://app.example.com/ | grep -o 'Build [0-9a-z-]*'
```

## Tests

```sh
make -C web test-fast                    # Go -short, Vitest, typecheck: the inner loop
make -C web test                         # full tier: -race, vet, generated-code check, script tests
make -C web e2e-install && make -C web e2e      # Playwright against the built binary (downloads Chromium)
```

Details in [web/docs/testing.md](web/docs/testing.md).

## Deploy in five steps

1. Prepare a Linux server with a normal user, key-only SSH and `loginctl enable-linger`.
2. Create `~/app/.env` on the server from `web/deploy/.env.example` (`APP_ENV=production`; fill in
   `SESSION_SECRET` and `PUBLIC_ORIGIN`). `deploy.sh` refuses a server `.env` that is not production.
3. Install the systemd user units from `web/deploy/`.
4. Run `web/scripts/deploy.sh user@host --check`, then `PUBLIC_URL=https://app.example.com web/scripts/deploy.sh user@host`.
5. Put NGINX with TLS in front and run `web/scripts/smoke.sh` against the public URL.

Full walkthrough, rollback and restore: [web/docs/deploy.md](web/docs/deploy.md).

## Backups

The binary writes a verified snapshot daily (systemd timer), `web/scripts/pull-backups.sh` copies them
to another machine and alerts when the newest is stale, and `web/scripts/restore.sh --drill` proves a
restore. See [web/docs/backups.md](web/docs/backups.md).

## HTTPS

NGINX server block, certificates, redirect, HSTS and the matching `.env` settings:
[web/docs/https.md](web/docs/https.md). The proxy sets HSTS; the app never sends it, so the proxy's staged
rollout is the one browsers see.

## Rename it

```sh
web/scripts/rename.sh github.com/you/<name> <name>
```

This rewrites the Go module path, the binary (`web/dist/<name>`), cookie, unit and database names, the
server paths (`~/<name>`) and the page titles, and renames `web/api/cmd/<name>` and the unit files.
Run it on a clean git tree; `web/scripts/rename.test.sh` covers it.

The shipped name `app` is also an ordinary word, a Go package (`internal/app`), the embed
directory (`internal/web/app`), the `/app/` URL mount and the `APP_` environment prefix. The script
therefore never replaces the bare word: it reads the current module path and name from
`web/api/go.mod` and `web/api/cmd/`, and replaces the name only in project-name contexts (listed in
the header of the script). Those other uses stay as they are. It works for any name that is not
reserved: names the repository itself uses as a directory or variable word (`web`, `api`, `data`,
`scripts`, `releases`, ...) are rejected with a clear error (the `RESERVED` list in
`web/scripts/rename.sh`). Prose that merely mentions the name is left alone: edit this README and the page copy
yourself.

**Rename before a real deployment.** A fresh checkout is called `app`, which is generic, and that name
is used for the server directory `~/<name>`, the units `<name>.service`, `<name>-backup.service` and
`<name>-backup.timer`, the database `<name>.db`, and on your Mac the backup agent (`com.<name>.backup-pull`,
`~/.config/<name>/`, `~/Library/Logs/<name>/`). While `web/api/cmd/` still holds `app`, on a shared
server or Mac they can clash with another app that uses the same names, and a documented restore
could then stop and start the other app. Running `web/scripts/rename.sh` before the first deploy is the
supported way to get distinctive names everywhere at once; overriding single variables is not (see
[web/docs/deploy.md](web/docs/deploy.md)). `web/scripts/rename.sh --check <module-path> <name>` validates a rename (name
rules, reserved words, and a check that renaming back would be exact) without changing anything.

## Layout

```
.
├── README.md  CLAUDE.md  AGENTS.md  .gitignore  .gitattributes
├── .claude/                settings.json, hooks/post-edit.sh, commands/, skills/ (new-web-app, new-ios-app)
├── .github/workflows/      ci.yml (fast, full, e2e)
├── docs/superpowers/       design history (specs and plans)
├── ios/                    reserved for the native iOS app (README only for now)
└── web/                    everything that belongs to the web platform
    ├── Makefile            dev, build, test-fast, test, e2e, api (run as: make -C web test)
    ├── .nvmrc  package.json  pnpm-lock.yaml  vite.config.ts
    ├── deploy/             files installed on a server: systemd units, nginx example, the server env template
    ├── docs/               deploy.md, https.md, backups.md, testing.md
    ├── scripts/            deploy, smoke, restore, pull-backups, gen-api, rename, build-id, layout guard and their *.test.sh
    ├── dist/               compiled binary from make -C web build (ignored)
    ├── src/                React app (pages, API client, tests)
    ├── test/               e2e/ (Playwright tests), README.md
    └── api/                Go module
        ├── cmd/app/        command line
        ├── internal/       config, db, auth, notes, storage, backup, server, app, web, ...
        ├── tests/          integration tests
        └── openapi.yaml    API contract
```

## Agent tooling

[CLAUDE.md](CLAUDE.md) holds the layout rules, exact commands, conventions and a dated log.
[AGENTS.md](AGENTS.md) is the short tool-neutral version. `.claude/` has shared permissions, a
post-edit hook (Go edits run `go vet` and `go test -short` for the package; web edits run
`tsc`), and the `/test` and `/backup-check` commands.

`.claude/skills/` holds two agent skills that start new projects from this repo: `new-web-app` turns a
committed copy of it into an app (web/scripts/rename.sh plus hosting settings) and `new-ios-app` scaffolds
an iOS app. They are not part of what a new app copies: the wrapper leaves that directory out, and
`web/scripts/rename.sh` and the layout guard ignore it. Their tests run with `make -C web test-skills`.

## Replace these placeholders

- [ ] Public page copy in `web/api/internal/web/pages/` (home, FAQ, privacy, terms, support)
- [ ] The support email `support@example.com` in those pages
- [ ] This README's title and text
- [ ] A `LICENSE` file: none is included, choose one yourself
- [ ] The server's `.env` from `web/deploy/.env.example`, with a real `SESSION_SECRET` and `PUBLIC_ORIGIN`
- [ ] The git remote, and the `app.example.com` examples in `web/deploy/` and `web/docs/`
