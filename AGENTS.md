# AGENTS.md

Instructions for AI coding assistants. The fuller version is [CLAUDE.md](CLAUDE.md); read it
and the files in [docs/](docs/) before larger changes.

## What this is

A starter for a small web product: a Go + SQLite server (in `web/api/`) that
serves a JSON API, a React + TypeScript app (in `web/`) and static public pages from one
binary, with backups, deploy scripts and tests.

## Layout

- `web/api/cmd/goweb` command line (`serve`, `user create`, `backup [--label NAME]`, `verify-backup`,
  `schema-version`)
- `web/api/internal/` packages: `config`, `db`, `auth`, `notes`, `storage`, `backup`,
  `server`, `app`, `web` (embedded pages and app), `apigen` (generated models)
- `web/api/tests/` integration tests; `web/api/openapi.yaml` is the API contract
- `web/src/` React app; `web/e2e/` Playwright tests
- `deploy/` systemd units and deploy, restore, backup-pull and smoke scripts; `scripts/` tooling

## Commands

- `make test-fast` quick tier (Go `-short`, Vitest, typecheck)
- `make test` full tier (race, vet, generated-code check, script tests)
- `make e2e-install` once, then `make e2e` for Playwright
- `make api` regenerate generated code; `make build` build the binary; `make dev` run locally
- Web commands need Node 24 with corepack; use pnpm only, never npm or yarn.

## Rules

1. Write the failing test first, then the code. Run `make test-fast` before saying you are done.
2. Never edit generated files (`web/api/internal/apigen/*.gen.go`, `web/src/api/schema.d.ts`).
   Change `web/api/openapi.yaml` and run `make api`.
3. Do not edit `web/api/internal/web/app/` by hand; it is filled by `make build`.
4. Respect the import direction enforced by `web/api/tests/boundary_test.go`.
5. Migrations are numbered and immutable once released; add a new one instead of editing.
6. Never commit secrets: runtime config is environment variables (see `.env.example`); `.env`
   is gitignored.
7. Do not add dependencies without a reason; do not store absolute file paths in the database.
8. Keep docs, the public pages and `.env.example` in step with behavior changes.
9. The reverse proxy sets HSTS; the app never sends `Strict-Transport-Security`.
