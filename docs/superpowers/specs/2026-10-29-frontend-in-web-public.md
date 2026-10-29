# Frontend in web/src and web/public, one binary out

Date: 2026-10-29. Status: approved by the author's rule in `CLAUDE.md` ("Layout rule"); this spec fixes the mechanics.

## Goal

All frontend code lives in `web/src` (React) or `web/public` (everything Go renders: public pages, CSS, fonts, images,
icons, Markdown). `web/api` is Go only. The release is still one static Go binary with only the server `.env` beside it.

## Layout

```
web/public/pages/*.html      public pages (was web/api/internal/web/pages/)
web/public/static/...        CSS, fonts, icons (was web/api/internal/web/static/); served at /static/<path>
web/api/internal/web/public/ GENERATED copy of web/public (gitignored, committed .gitkeep), the go:embed source
web/api/internal/web/app/    GENERATED Vite output (unchanged)
```

URLs do not change (`/`, `/faq`, ..., `/static/style.css`, `/app/`).

## Mechanics

1. `web/scripts/sync-public.sh` empties `web/api/internal/web/public/` (keeping `.gitkeep`) and copies `web/public/`
   into it. Plain `cp`/`rsync`-free bash, no Node, so Go-only tiers can run it. It refuses to run when `web/public/pages`
   or `web/public/static` is missing, and prints what it copied.
2. `go:embed` becomes `public/pages/*.html public/static/* all:app` (embedded paths gain the `public/` prefix; `web.go`
   `fs.Sub`s accordingly).
3. Everything that compiles or tests the Go module runs the sync first: `make test-fast`, `make test`, `make build`,
   `make dev`, `deploy.sh` (gate and build), `web/test/e2e/global-setup.ts`, CI jobs, `pnpm build` (via `prebuild`).
   The Go `web` package fails with a message naming `web/scripts/sync-public.sh` when the embedded `public/` is empty;
   it never silently serves nothing.
4. Unit tests of the `web` package keep using fixtures; tests that need the real pages (`public_test.go`, the
   `@@BUILD_ID@@`-once check, the privacy-body check) read the embedded tree after the sync.
5. A boundary/layout guard fails when a tracked file with a frontend extension (`.html .css .woff .woff2 .svg .png .ico
   .js .ts .tsx`) sits under `web/api` (the generated, ignored folders are not tracked, so they pass).

## Touch list

`web.go`, `web_test.go`, `tests/embed_test.go`, `tests/public_test.go`; `web/Makefile`; `web/package.json` (`prebuild`);
`web/scripts/` (`sync-public.sh` + test, `smoke.sh` CSS_FILE default, `rename.sh` + test, `deploy.sh` + test,
`layout.test.sh`); `.gitignore`; `.github/workflows/ci.yml`; `.claude/hooks/post-edit.sh`; `.claude/skills/new-web-app/`
(`scaffold.sh` PAGES_GLOB, tests); `web/test/e2e/global-setup.ts`; docs (`CLAUDE.md`, `README.md`, `AGENTS.md`,
`web/docs/testing.md`, `web/docs/deploy.md` if it names the paths).

## Trade-off accepted

A fresh clone can no longer run `go test ./...` or `go build` with no preparation: it needs `bash web/scripts/sync-public.sh`
(or any `make` target, which does it). That is the price of keeping frontend files out of `web/api`, because `go:embed`
cannot reach outside the module. The sync step is Node-free so the Go-only tiers stay cheap.

## Not changing

URLs, the build-id placeholder rules, ETag behavior, the React build output location, rename semantics for the bare word `app`.
