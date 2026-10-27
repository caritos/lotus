# goweb Starter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build goweb, an open-source starter: a single Go binary serving a JSON API, an embedded React + TypeScript + Vite app and static public pages, backed by SQLite, with tests, backups, deploy scripts, HTTPS docs and agent tooling.

**Architecture:** Go module in `web/api/` (stdlib `net/http`, `modernc.org/sqlite`), frontend at the `web/` root built into `web/api/internal/web/app` and embedded with `go:embed`. An example app (sign-in plus notes with photo upload) gives every tier something real to test. Backups are pure-Go `VACUUM INTO` snapshots pulled off-site with rsync over SSH.

**Tech Stack:** Go (current stable, pinned in `go.mod`), `modernc.org/sqlite`, `golang.org/x/crypto/bcrypt`, `oapi-codegen` (models only), Vite + React + TypeScript strict, pnpm, Vitest + Testing Library + MSW, Playwright, `openapi-typescript` + `openapi-fetch`, systemd user service, NGINX docs, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-27-goweb-starter-design.md`

## Global Constraints

- No Docker, no cgo, no Cloudflare/tunnel mentions anywhere (code or docs), no S3 or cloud storage, no Postgres/MySQL, no personal domains, paths or credentials in the repo.
- Go module lives in `web/api/` with its own `go.mod` (module name `goweb`); `package.json` is at `web/`. Frontend builds to `web/api/internal/web/app` (`build.outDir`, `emptyOutDir: false`). Build order: `pnpm build` then `go build`. `.gitkeep` files keep a fresh clone compiling.
- Runtime dirs are `web/db/`, `web/logs/`, `web/storage/` (gitignored contents, `.gitkeep` kept). `DATA_DIR` defaults to `.`; `make dev` sets it to `web/`; the e2e harness uses a temp dir. Vite `server.watch.ignored` excludes the three dirs.
- Config is environment variables only (defaults in code, documented in `.env.example`). In production (`APP_ENV=production`) the server refuses to start if `SESSION_SECRET` or `PUBLIC_ORIGIN` is missing.
- SQLite: WAL, foreign keys on, busy timeout, `_txlock=immediate`; UUID text keys, Unix-ms integer timestamps, soft delete via `archived_at`; numbered embedded `.sql` migrations applied in a transaction, recorded in `schema_migrations`, never edited once released.
- Server: all `http.Server` timeouts set, graceful shutdown on SIGINT/SIGTERM, `umask 077`, body size limits, `/healthz` returns JSON including injected `version` and `commit` (`-ldflags`). Static assets have a known `Content-Length` (no streaming compression), an `ETag`, `immutable` for hashed `assets/*`, `no-cache` for `index.html`.
- Web: TypeScript `strict`, no `any`; API types and client only from generated OpenAPI output; pnpm only (never npm/yarn); Node pinned in `.nvmrc` and `engines`; `packageManager` set; `pnpm-lock.yaml` committed.
- Tests: Go unit tests beside code (`foo_test.go`), Go integration tests in `web/api/tests/`, Vitest beside source, Playwright in `web/e2e/`. Fast tier `go test -short ./...`; full tier `go test -race ./...` plus `go vet ./...`. TDD: failing test first, see it fail for the right reason.
- Service model: non-root systemd user service with `loginctl enable-linger` verified by the deploy; system-service variant documented only.
- Public pages `/`, `/faq`, `/privacy`, `/terms`, `/support` are plain static HTML (no template engine, no client JS), sharing one CSS file; React app mounted under `/app/`.
- Every commit message ends with the attribution lines from the session's system-reminder. Commit after each green step group. Never force push; do not push to `main` without asking.

## Review Focus

Failure modes the spec implies that no feature task would otherwise exercise (each has a test in the owning task):

1. A fresh clone with only `.gitkeep` in the embed dir compiles and serves a clear "frontend not built" page instead of a blank 404 (Task 3).
2. A deep link such as `/app/notes/123` serves `index.html`, while a missing `/app/assets/x.js` is a real 404 (Task 3).
3. A stored filename containing `../` or an absolute path can never read or write outside `storage/` (Task 7).
4. An upload with a spoofed extension or over 5 MB is rejected (415 / 413) and leaves no file behind (Task 7).
5. A backup taken while another connection is writing still passes `PRAGMA integrity_check` (Task 9).

---

### Task 1: Repo bootstrap, config, server skeleton, `/healthz`

**Files:**
- Create: `.gitignore`, `.env.example`, `.nvmrc`, `Makefile` (targets `dev`, `build`, `test-fast`, `test`, `e2e`, `api` as stubs filled in later tasks), `web/api/go.mod`, `web/api/cmd/goweb/main.go`, `web/api/internal/config/config.go`, `web/api/internal/version/version.go`, `web/api/internal/server/server.go`, `web/{db,logs,storage}/.gitkeep`
- Test: `web/api/internal/config/config_test.go`, `web/api/internal/server/server_test.go`

**Interfaces:**
- Produces: `config.Config{Addr, DataDir, PublicOrigin, SessionSecret, Env string; SecureCookies bool; TrustedProxy string; SessionTTL time.Duration}`; `config.Load(getenv func(string) string) (Config, error)`; `version.Version`, `version.Commit` (strings set by ldflags); `server.New(cfg config.Config, deps server.Deps) http.Handler` where `server.Deps` starts empty and grows; `server.NewHTTPServer(cfg config.Config, h http.Handler) *http.Server` (ReadHeader 5s, Read 30s, Write 60s, Idle 120s, `MaxHeaderBytes` 1 MiB).

- [ ] **Step 1:** `git init` in `~/src/goweb`, run `go version`, create `go.mod` (`module goweb`, current Go version) and the folders above.
- [ ] **Step 2:** Write failing tests: `TestLoadDefaults` (empty env gives `Addr ":8080"`, `DataDir "."`, `Env "development"`), `TestLoadProductionRequiresSecrets` (`APP_ENV=production` without `SESSION_SECRET` or `PUBLIC_ORIGIN` returns an error naming the missing key), `TestHealthz` (`GET /healthz` returns 200 JSON `{"status":"ok","version":...,"commit":...}`), `TestHTTPServerTimeouts`.
- [ ] **Step 3:** Run `cd web/api && go test ./...`; expected FAIL (undefined).
- [ ] **Step 4:** Implement the interfaces; `main.go` loads config, applies `syscall.Umask(0o077)`, serves with `signal.NotifyContext` graceful shutdown (10s). `.env.example` lists every variable with a comment.
- [ ] **Step 5:** Run `go test -short ./... && go vet ./...`; expected PASS. Commit.

### Task 2: Database open, migrations, test helper

**Files:**
- Create: `web/api/internal/db/db.go`, `web/api/internal/db/migrate.go`, `web/api/internal/db/migrations/embed.go`, `web/api/internal/db/migrations/0001_init.sql` (tables `users`, `sessions`, `notes` with UUID text keys, ms timestamps, `archived_at`, `notes.photo` nullable relative filename), `web/api/internal/testutil/db.go`
- Test: `web/api/internal/db/db_test.go`, `web/api/internal/db/migrate_test.go`

**Interfaces:**
- Produces: `db.Open(path string) (*sql.DB, error)` (DSN per Global Constraints; pool capped; `:memory:` gets one connection); `db.Migrate(ctx context.Context, d *sql.DB) error`; `db.MigrateFS(ctx, d, fsys fs.FS) error` (used by tests with fixture migrations); `testutil.NewDB(t testing.TB) *sql.DB` (temp-file DB under `t.TempDir()`, migrated, closed on cleanup).

- [ ] **Step 1:** Failing tests: `TestOpenSetsPragmas` (`journal_mode=wal`, `foreign_keys=1`), `TestMigrateFreshAppliesAll`, `TestMigrateIsIdempotent`, `TestMigrateUpgradesPopulatedDB` (apply `0001` from a fixture FS, insert rows, apply `0002` fixture, rows survive, `PRAGMA foreign_key_check` empty), `TestMigrateFailureRollsBack` (a fixture with bad SQL returns an error naming the file and leaves `schema_migrations` without that version).
- [ ] **Step 2:** Run `go test ./internal/db/...`; expected FAIL.
- [ ] **Step 3:** Implement `Open`, `Migrate`/`MigrateFS` (sorted by filename, one transaction per migration, version recorded), the embed file, and `0001_init.sql`.
- [ ] **Step 4:** Run `go test -short ./... && go vet ./...`; expected PASS. Commit.

### Task 3: Embedded web layer (public pages, static assets, SPA mount)

**Files:**
- Create: `web/api/internal/web/web.go`, `web/api/internal/web/pages/{index,faq,privacy,terms,support}.html`, `web/api/internal/web/static/style.css`, `web/api/internal/web/app/.gitkeep`
- Modify: `web/api/internal/server/server.go` (mount `web.Handler()`)
- Test: `web/api/internal/web/web_test.go`

**Interfaces:**
- Produces: `web.Handler() http.Handler` serving `/`, `/faq`, `/privacy`, `/terms`, `/support`, `/static/*`, `/app/*`; `web.AppBuilt() bool` (true when `app/index.html` is embedded).

- [ ] **Step 1:** Failing tests via `httptest`: `TestPublicPagesHaveBodyText` (each page 200, `text/html`, non-empty `<h1>` and at least 200 bytes of text), `TestStaticETagAndContentLength`, `TestHashedAssetsImmutable` (`/app/assets/*` has `Cache-Control: public, max-age=31536000, immutable`), `TestIndexNoCache`, `TestSPAFallbackDeepLink` (`/app/notes/123` returns the index when built), `TestMissingAssetIs404` (`/app/assets/nope.js`), `TestFrontendNotBuiltMessage` (with no `app/index.html`, `/app/` returns 503 with a readable "run pnpm build" page), `TestEmbedContainsMigrations` lives in Task 10.
- [ ] **Step 2:** Run; expected FAIL.
- [ ] **Step 3:** Implement with `embed.FS` (`//go:embed pages/*.html static/* all:app`), computing a SHA-256 `ETag` per file at startup, setting `Content-Length` explicitly, no compression middleware.
- [ ] **Step 4:** Write the five pages and `style.css` as real, generic copy (placeholders `{{`-free; "Last updated" hard-coded).
- [ ] **Step 5:** Run `go test -short ./...`; expected PASS. Commit.

### Task 4: Authentication

**Files:**
- Create: `web/api/internal/auth/{password.go,session.go,throttle.go,handlers.go,middleware.go}`, `web/api/cmd/goweb/user.go` (subcommand `goweb user create <email>`)
- Test: `web/api/internal/auth/*_test.go`, `web/api/cmd/goweb/user_test.go`

**Interfaces:**
- Consumes: `testutil.NewDB`, `config.Config`.
- Produces: `auth.HashPassword(pw string) (string, error)`, `auth.CheckPassword(hash, pw string) bool`; `auth.NewService(d *sql.DB, cfg config.Config, now func() time.Time) *auth.Service` with `CreateUser(ctx, email, password string) (User, error)` (email lowercased and trimmed; duplicate returns `auth.ErrEmailTaken`), `Login(ctx, email, password, ip string) (token string, User, error)` (returns `auth.ErrBadCredentials` or `auth.ErrThrottled`), `Logout(ctx, token string) error`, `UserFor(ctx, token string) (User, error)`; session tokens are 32 random bytes, stored as HMAC-SHA256 with `SessionSecret`; `auth.Middleware(s *Service) func(http.Handler) http.Handler` puts `User` in context (`auth.FromContext`); `auth.Handlers(s *Service) http.Handler` mounts `POST /api/login`, `POST /api/logout`, `GET /api/me`. Cookie: `HttpOnly`, `SameSite=Lax`, `Secure` when `SecureCookies`.

- [ ] **Step 1:** Failing tests: `TestHashAndCheck`, `TestCreateUserNormalizesEmail`, `TestDuplicateEmailCaseInsensitive`, `TestLoginSuccessSetsCookieAttributes`, `TestLoginWrongPasswordGeneric401` (same body for unknown user and wrong password), `TestSessionExpires` (fake clock), `TestLogoutInvalidatesSession`, `TestThrottleAfterFiveFailures` (per user+IP, IPv6 grouped by /64, bounded map), `TestUserCreateCommandReadsPasswordFromStdin`.
- [ ] **Step 2:** Run; expected FAIL.
- [ ] **Step 3:** Implement. Call `auth.UseFastHashingForTests()` (min bcrypt cost, panics outside a test binary) from `TestMain` in every package whose tests hash passwords. Wire `user create` into `main.go`.
- [ ] **Step 4:** Run `go test -short ./... && go vet ./...`; expected PASS. Commit.

### Task 5: Security middleware and logging

**Files:**
- Create: `web/api/internal/server/middleware.go`, `web/api/internal/logging/logging.go`
- Modify: `web/api/internal/server/server.go`
- Test: `web/api/internal/server/middleware_test.go`, `web/api/internal/logging/logging_test.go`

**Interfaces:**
- Produces: `server.SecurityHeaders(next) http.Handler`, `server.SameOrigin(publicOrigin string) func(http.Handler) http.Handler` (state-changing methods must carry an `Origin` equal to `PUBLIC_ORIGIN`; `GET`/`HEAD` exempt), `server.BodyLimit(n int64) func(http.Handler) http.Handler`, `server.TrustedProxy(cidrs string) func(http.Handler) http.Handler` (honors `X-Forwarded-For` only from listed proxies); `logging.New(dataDir string, maxBytes int64, keep int) (*slog.Logger, io.Closer, error)` writing `logs/app.log`, rotating by size.

- [ ] **Step 1:** Failing tests: `TestSecurityHeadersPresent`, `TestSameOriginRejectsForeignOrigin` (403), `TestSameOriginAllowsMatching`, `TestBodyLimit413`, `TestForwardedForIgnoredFromUntrustedPeer`, `TestLogRotatesAtMaxBytes` (keeps `keep` generations).
- [ ] **Step 2:** Run; expected FAIL.
- [ ] **Step 3:** Implement and chain in this order: proxy, request logging, security headers, same-origin, body limit.
- [ ] **Step 4:** Run `go test -short ./...`; expected PASS. Commit.

### Task 6: OpenAPI contract and generated models

**Files:**
- Create: `web/api/openapi.yaml`, `web/api/internal/apigen/models.gen.go`, `web/api/oapi-codegen.yaml`, `scripts/gen-api.sh`, `web/src/api/schema.d.ts` (generated)
- Modify: `Makefile` (`api` target), `web/package.json` (add `openapi-typescript`, `openapi-fetch`)
- Test: `scripts/gen-api.test.sh`

**Interfaces:**
- Produces: spec paths `POST /api/login`, `POST /api/logout`, `GET /api/me`, `GET/POST /api/notes`, `GET/PATCH/DELETE /api/notes/{id}`, `PUT/DELETE /api/notes/{id}/photo`, `GET /api/notes/{id}/photo`, `GET /healthz`; schemas `User{id,email}`, `Note{id,title,body,photo(bool),created_at,updated_at}` (timestamps Unix ms integers), `Error{error}`; generated Go types in package `apigen`.

- [ ] **Step 1:** Failing test `gen-api.test.sh`: runs `scripts/gen-api.sh` and asserts `git diff --exit-code` on generated files after a clean regenerate; fails now because nothing exists.
- [ ] **Step 2:** Write the spec, the codegen config (models only, no router), the script (Go via `go run github.com/oapi-codegen/oapi-codegen/v2/cmd/oapi-codegen@<pinned>`, TS via `pnpm exec openapi-typescript`), and the `make api` target.
- [ ] **Step 3:** Run `make api && bash scripts/gen-api.test.sh`; expected PASS. Commit.
- [ ] **Step 4:** Switch Task 4's login/me bodies to the generated types where they apply, run `go test -short ./...`.

### Task 7: Notes and photo storage

**Files:**
- Create: `web/api/internal/storage/storage.go`, `web/api/internal/notes/{store.go,handlers.go}`
- Modify: `web/api/internal/server/server.go` (mount authenticated `/api/notes`)
- Test: `web/api/internal/storage/storage_test.go`, `web/api/internal/notes/*_test.go`

**Interfaces:**
- Consumes: `testutil.NewDB`, `auth.FromContext`, `apigen.Note`.
- Produces: `storage.New(dir string) (*storage.Store, error)`; `(*Store).Save(ctx context.Context, r io.Reader, maxBytes int64) (name string, err error)` (content-sniffs JPEG/PNG/WebP, generates a UUID name with the sniffed extension; errors `storage.ErrTooLarge`, `storage.ErrUnsupportedType`; removes partial files on error); `Open(name string) (*os.File, error)` and `Delete(name string) error` (both reject any name that is not a bare generated filename with `storage.ErrInvalidName`); `notes.NewStore(d *sql.DB) *notes.Store` with `Create/List/Get/Update/Archive/SetPhoto` scoped by `userID`; `notes.Handlers(s *notes.Store, st *storage.Store) http.Handler` (upload limit 5 MiB; 413 and 415 mapping; photo served only to the owner).

- [ ] **Step 1:** Failing tests: `TestSaveSniffsContentNotExtension` (a PNG named `a.exe` saves as `.png`), `TestSaveRejectsText415` (renamed `.jpg` that is text), `TestSaveRejectsOver5MiB413AndLeavesNoFile`, `TestOpenRejectsTraversal` (`../x`, `/etc/passwd`, `a/b`), `TestNotesCRUDScopedToUser` (user B gets 404 on user A's note), `TestArchiveKeepsPhotoFile`, `TestPhotoRequiresOwner`, `TestStoresRelativeFilenameOnly`.
- [ ] **Step 2:** Run; expected FAIL.
- [ ] **Step 3:** Implement the packages and handlers.
- [ ] **Step 4:** Run `go test -short ./... && go vet ./...`; expected PASS. Commit.

### Task 8: React + TypeScript frontend

**Files:**
- Create: `web/package.json`, `web/pnpm-lock.yaml`, `web/tsconfig.json` (`strict`), `web/vite.config.ts` (`build.outDir "api/internal/web/app"`, `emptyOutDir false`, dev proxy `/api` and `/healthz` to `http://localhost:8080`, `server.watch.ignored` for `db`, `logs`, `storage`), `web/index.html`, `web/src/{main.tsx,App.tsx,api/client.ts,pages/Login.tsx,pages/Notes.tsx,pages/NoteEdit.tsx,test/setup.ts,test/handlers.ts}`
- Test: `web/src/**/*.test.tsx`

**Interfaces:**
- Consumes: generated `web/src/api/schema.d.ts`.
- Produces: `client` (an `openapi-fetch` instance with `credentials: "include"`); routes `/app/login`, `/app/notes`, `/app/notes/:id` under router `basename="/app/"`; `vite.config.ts` `base: "/app/"`.

- [ ] **Step 1:** Failing Vitest tests with MSW handlers: `Login shows error on 401`, `Login redirects to notes on success`, `Notes lists notes from the API`, `NoteEdit saves title and body`, `NoteEdit uploads a photo and shows it`, `unauthenticated visit redirects to login`.
- [ ] **Step 2:** Run `cd web && pnpm install && pnpm test`; expected FAIL.
- [ ] **Step 3:** Implement the pages with the generated client only (no hand-written API types, no `any`).
- [ ] **Step 4:** Run `pnpm test && pnpm exec tsc --noEmit && pnpm build`; expected PASS and files appear in `web/api/internal/web/app/`.
- [ ] **Step 5:** Add `make dev` (Go server with `DATA_DIR=web` plus Vite) and commit.

### Task 9: Backups, restore drill, off-site pull

**Files:**
- Create: `web/api/internal/backup/backup.go`, `web/api/cmd/goweb/backup.go` (subcommand `goweb backup [--keep N]`), `deploy/restore.sh`, `deploy/pull-backups.sh`, `deploy/test.sh`
- Test: `web/api/internal/backup/backup_test.go`, `deploy/test.sh`

**Interfaces:**
- Consumes: `db.Open`, `testutil.NewDB`.
- Produces: `backup.Run(ctx context.Context, d *sql.DB, dataDir string, keep int, now time.Time) (backup.Result, error)` writing `<dataDir>/backups/<UTC timestamp>/{goweb.db,storage/}` (snapshot via `VACUUM INTO`, then a copy of `storage/`, then prune to the newest `keep`); `Result{Dir string; Files int}`; `deploy/restore.sh <backup-dir> [--drill]` (verifies `integrity_check`, checks every note photo exists in the restored `storage/`, safety-copies current data, stops/restarts the user service, health-checks, rolls back on failure; `--drill` restores into a scratch dir only); `deploy/pull-backups.sh` (rsync over SSH with a dedicated key, `integrity_check` on each pulled snapshot, quarantine failures to `failed/`, alert when newest is older than 3 days).

- [ ] **Step 1:** Failing Go tests: `TestBackupIntegrityOK`, `TestBackupWhileWriting` (a goroutine inserts rows throughout; the snapshot passes `integrity_check`), `TestBackupCopiesStorage`, `TestPruneKeepsNewest`, `TestBackupFilesOwnerOnly` (mode `0600`/`0700`).
- [ ] **Step 2:** Failing shell tests in `deploy/test.sh` using a local directory as the fake remote: `restore drill passes on good backup`, `restore drill fails on corrupt db`, `restore drill fails when a referenced photo is missing`, `pull rejects corrupt snapshot into failed/`, `pull alerts when newest backup is stale`.
- [ ] **Step 3:** Run both; expected FAIL.
- [ ] **Step 4:** Implement the Go package, subcommand and scripts.
- [ ] **Step 5:** Run `go test -race ./internal/backup/... && bash deploy/test.sh`; expected PASS. Commit.

### Task 10: Go integration tests in `tests/`

**Files:**
- Create: `web/api/tests/{main_test.go,auth_flow_test.go,notes_flow_test.go,backup_restore_test.go,embed_test.go,boundary_test.go}`, `web/api/internal/testutil/server.go`

**Interfaces:**
- Produces: `testutil.NewServer(t testing.TB) *testutil.App` where `App{URL string; Client *http.Client (cookie jar); DB *sql.DB; DataDir string; CreateUser func(email, pw string)}` boots the real `server.New` wiring against a temp SQLite and temp `DATA_DIR`.

- [ ] **Step 1:** Write tests (all `testing.Short()`-skipped): `TestAuthFlow` (login, `/api/me`, logout, `/api/me` 401), `TestNotesFlowWithPhoto` (create, upload, fetch photo bytes, archive), `TestBackupRestoreRoundTrip` (backup, mutate, restore into scratch, rows and photo match), `TestEmbeddedMigrationsPresent` (the built binary's embedded FS lists every `migrations/*.sql`), `TestEmbeddedAppPresentWhenBuilt`, `TestImportDirection` (parses imports: `internal/notes` and `internal/auth` do not import `internal/server`; `internal/db` imports no feature package).
- [ ] **Step 2:** Run `go test -race ./tests/...`; expected FAIL until `testutil.NewServer` exists.
- [ ] **Step 3:** Implement `testutil.NewServer`; fix any real defects the tests expose in earlier tasks.
- [ ] **Step 4:** Run `go test -race ./... && go vet ./...`; expected PASS. Commit.

### Task 11: Playwright end-to-end suite

**Files:**
- Create: `web/e2e/{playwright.config.ts,global-setup.ts,auth.spec.ts,notes.spec.ts,photo.spec.ts,notfound.spec.ts}`, `web/e2e/fixtures/photo.png`
- Modify: `web/package.json` (`@playwright/test`), `Makefile` (`e2e`)

**Interfaces:**
- Produces: `global-setup.ts` builds the frontend and binary (`pnpm build` then `go build -o <tmp>/goweb`), starts it on a free port with a temp `DATA_DIR`, creates user `e2e@example.com` with `goweb user create`, and exports the base URL; teardown stops it and deletes the temp dir.

- [ ] **Step 1:** Write specs: `sign in and out`, `wrong password shows error`, `create edit delete note`, `upload photo and see it after reload`, `unknown URL shows 404 page`, `signed-out visit to /app/notes redirects to login`.
- [ ] **Step 2:** Run `make e2e`; expected FAIL until the harness works, then PASS.
- [ ] **Step 3:** Commit (browsers are installed with `pnpm exec playwright install`, documented in `docs/testing.md`).

### Task 12: Deploy, smoke check, systemd, HTTPS docs

**Files:**
- Create: `deploy/goweb.service`, `deploy/deploy.sh`, `deploy/smoke.sh`, `deploy/nginx.conf.example`, `docs/deploy.md`, `docs/https.md`, `docs/backups.md`
- Modify: `deploy/test.sh`

**Interfaces:**
- Produces: `deploy/deploy.sh <user@host>` (validates host, SSH key auth with `BatchMode=yes`, verifies `Linger=yes`, builds, runs `goweb backup` on the server first, uploads to `~/goweb/releases/<version>/`, verifies checksum, switches the `current` symlink atomically, restarts, health-checks on loopback, rolls back automatically only when the release ran no migration, otherwise prints the restore command, then runs `smoke.sh`); `deploy/smoke.sh <url> <expected-version>` (`/healthz` build equals expected, home page has the app name, `/nope` is 404); `goweb.service` (user unit: `NoNewPrivileges`, `ProtectSystem=strict`, `ReadWritePaths`, `UMask=0077`, `EnvironmentFile=`, binds `0.0.0.0`).

- [ ] **Step 1:** Add failing shell tests to `deploy/test.sh` with a fake `ssh`/`rsync` on `PATH` and a fake HTTP server: `deploy aborts when linger is off`, `deploy rolls back on failed health check`, `deploy keeps previous release`, `smoke fails on version mismatch`, `smoke fails when /nope is not 404`, `deploy rejects host starting with a dash`.
- [ ] **Step 2:** Run; expected FAIL.
- [ ] **Step 3:** Implement scripts, unit file and docs. `docs/https.md` covers the NGINX server block, certbot certificates, HTTP-to-HTTPS redirect, HSTS, proxy headers, the matching `.env` values (`PUBLIC_ORIGIN`, `SECURE_COOKIES=true`, `TRUSTED_PROXY`), and the system-service variant. No tunnel products are mentioned.
- [ ] **Step 4:** Run `bash deploy/test.sh`; expected PASS. Commit.

### Task 13: Agent tooling, CI, rename script, README

**Files:**
- Create: `CLAUDE.md`, `AGENTS.md`, `README.md`, `.claude/settings.json`, `.claude/commands/{test.md,backup-check.md}`, `.claude/hooks/post-edit.sh`, `.github/workflows/ci.yml`, `scripts/rename.sh`, `scripts/rename.test.sh`, `docs/testing.md`
- Modify: `Makefile` (final targets)

**Interfaces:**
- Produces: `scripts/rename.sh <module-path> <name>` rewriting the Go module path and imports, binary and command name, env var prefix, systemd unit and file names, and `.claude` references; `.claude/hooks/post-edit.sh` (Go edits run `go vet` and `go test -short` in `web/api`; `web/` edits run `pnpm exec tsc --noEmit`); `/backup-check` (newest backup age, `integrity_check`, flags older than 3 days); CI jobs `fast`, `full` (`-race`, `go vet`, `make api` diff check, embed check) and `e2e`.

- [ ] **Step 1:** Failing test `rename.test.sh`: copies the repo to a temp dir, runs `rename.sh example.com/acme/shop shop`, asserts no `goweb` string remains outside `docs/` history and that `go build ./... && go test -short ./...` pass in the copy.
- [ ] **Step 2:** Run; expected FAIL.
- [ ] **Step 3:** Implement `rename.sh`; write `CLAUDE.md` (layout and layering rules, exact fast/full test commands, run/verify/deploy, dated Done / Not yet verified / Deferred log), the short tool-neutral `AGENTS.md`, `.claude/` files, CI workflow, `README.md` (clone, `make dev`, `make build`, deploy in five steps) and `docs/testing.md`.
- [ ] **Step 4:** Run the full verification: `make test` (full tier, clean rebuild with `go clean -testcache`), `make e2e`, `bash deploy/test.sh`, `bash scripts/rename.test.sh`; expected all PASS. Record results in the `CLAUDE.md` log, grep the repo for `cloudflare` and `tunnel` (expected no matches) and for personal domains or paths (expected none), then commit.
