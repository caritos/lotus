# AGENTS.md

Instructions for AI coding assistants. The fuller version is [CLAUDE.md](CLAUDE.md); read it
and the files in [docs/](docs/) before larger changes.

## What this is

A starter for a small web product: a Go + SQLite server (in `web/api/`) that
serves a JSON API, a React + TypeScript app (in `web/`) and static public pages from one
binary, with backups, deploy scripts and tests.

## Layout

- `web/api/cmd/app` command line (`serve`, `user create`, `backup [--label NAME]`, `verify-backup`,
  `schema-version`)
- `web/api/internal/` packages: `config`, `db`, `auth`, `notes`, `storage`, `backup`,
  `server`, `app`, `web` (embedded pages and app), `apigen` (generated models)
- `web/api/tests/` integration tests; `web/api/openapi.yaml` is the API contract
- `web/src/` React app; `web/test/e2e/` Playwright tests
- `ios/` reserved for the native iOS app (README only for now; scaffold with the new-ios-app skill)
- `web/deploy/` files installed on a server (systemd units, NGINX example); `web/scripts/` every repo-level script and its test (deploy, smoke, restore, pull-backups, build-id, rename, gen-api)
  (`build-id.sh` prints the build id)

## Commands

- `make -C web test-fast` quick tier (Go `-short`, Vitest, typecheck)
- `make -C web test` full tier (race, vet, generated-code check, script tests)
- `make -C web e2e-install` once, then `make -C web e2e` for Playwright
- `make -C web api` regenerate generated code; `make -C web build` build the binary; `make -C web dev` run locally
- Web commands need Node 24 with corepack; use pnpm only, never npm or yarn.

## Rules

1. Write the failing test first, then the code. Run `make -C web test-fast` before saying you are done.
2. Never edit generated files (`web/api/internal/apigen/*.gen.go`, `web/src/api/schema.d.ts`).
   Change `web/api/openapi.yaml` and run `make -C web api`.
3. Do not edit `web/api/embed/{pages,static,spa}` by hand; they are filled by `make -C web build` (or `web/scripts/sync-public.sh` for pages and static).
4. Respect the import direction enforced by `web/api/tests/boundary_test.go`.
5. Migrations are numbered and immutable once released; add a new one instead of editing.
6. Never commit secrets: runtime config is environment variables (see `web/deploy/.env.example`); `.env`
   is gitignored.
7. Do not add dependencies without a reason; do not store absolute file paths in the database.
8. Keep docs, the public pages and `web/deploy/.env.example` in step with behavior changes.
9. The reverse proxy sets HSTS; the app never sends `Strict-Transport-Security`.
10. New API routes are private by default (mounted behind `auth.Require`); a public one needs an entry, with a reason, in `publicRoutes` in `web/api/tests/guardrails_test.go`.
11. Money is stored as integer cents (no floats); the example schema has no money column.
12. Every HTML page shows a footer `Build YYYYMMDD-<short commit>` (UTC date, `-dirty` if modified): set only via `web/scripts/build-id.sh` and `-ldflags`, never hard-coded; a new page under `web/public/pages/` must contain `@@BUILD_ID@@` in its footer.
