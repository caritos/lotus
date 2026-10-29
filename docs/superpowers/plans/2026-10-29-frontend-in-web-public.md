# Plan: frontend in web/public (spec: ../specs/2026-10-29-frontend-in-web-public.md)

## Global Constraints

- Work only in this worktree (branch `worktree-frontend-to-web-public`). Commit after each task. Do not push.
- Test first (red, green, refactor); shell scripts get a failing `*.test.sh` first. macOS shell: BSD `sed -i ''`, no `grep -P`.
- Use `git mv` so history follows the files. Never edit generated code. pnpm only.
- Verify with `make -C web test-fast` after each task and `make -C web test` at the end (run the slow one in the background).
- `go:embed` cannot reach outside `web/api`; the embed copy is generated and gitignored, with a committed `.gitkeep`.
- Do not touch the bare word `app` rules in `rename.sh` (internal/app, internal/web/app, /app/, APP_ENV).

## Tasks

1. **sync-public.sh** (test first: `web/scripts/sync-public.test.sh`). Copies `web/public/{pages,static}` into
   `web/api/internal/web/public/`, keeps `.gitkeep`, removes stale files, fails if a source dir is missing. Add it to the
   `layout.test.sh` expected `web/scripts` set and to `make test-scripts`.
2. **Move files**: `git mv web/api/internal/web/pages web/public/pages`, `.../static web/public/static`. Create
   `web/api/internal/web/public/.gitkeep`; `.gitignore`: `web/api/internal/web/public/*` and `!.../.gitkeep`.
3. **web.go**: embed `public/pages/*.html public/static/* all:app`; adjust `mustLoad`, the `fs.Sub` calls and the route table
   to the `public/` prefix; when `public/` has no pages return an error that names `web/scripts/sync-public.sh`.
   Update `web_test.go`, `tests/embed_test.go`, `tests/public_test.go` (red first: they must fail on the old paths).
4. **Wire the sync** into `web/Makefile` (`test-fast`, `test`, `build`, `dev`), `web/package.json` `prebuild`,
   `deploy.sh` (before the gate and before the build; update `deploy.test.sh` fakes and add a case), `e2e/global-setup.ts`,
   `.github/workflows/ci.yml` (every job that runs `go test` or `go build`), `.claude/hooks/post-edit.sh` (editing under
   `web/public` runs the sync, skip the generated folder like `app/`).
5. **Guards**: a tracked-file check that no frontend extension sits under `web/api` (in `layout.test.sh`, with a
   self-test proving it fires); update `smoke.sh` CSS_FILE default to `web/public/static/style.css`; `rename.sh` and
   `rename.test.sh` page paths to `web/public/pages`.
6. **new-web-app skill**: `scaffold.sh` PAGES_GLOB, `scaffold.test.sh` and `scaffold.full.test.sh` paths; run the skill's
   full tier (`bash .claude/skills/new-web-app/tests/run.sh`).
7. **Docs**: `CLAUDE.md` (replace the "To do" line, layout tree, build-id and embed paragraphs), `README.md` line 176,
   `AGENTS.md`, `web/docs/testing.md`; add a dated Done entry to the Log.
8. **Verify**: clean rebuild (`rm -rf` the generated folders, `make -C web build`), run `dist/app` and `curl` `/`, `/privacy`,
   `/static/style.css`, `/app/`; `make -C web test` (background); `make -C web e2e`; grep the repo for the old paths.
