# Testing

Four tiers, from the quickest to the most realistic. The fast tier is the inner loop; the
full tier runs before every merge; end to end is separate because it downloads a browser.

| Tier | What | Where | Command |
|---|---|---|---|
| Go unit | package logic, handlers with `httptest`, in-memory or temp-file SQLite | beside the code (`foo_test.go`) | `go test -short ./...` |
| Go integration | real server wiring, migrations on populated data, auth flow, upload to `storage/`, backup and restore round trip, embed and import-direction checks | `web/api/tests/` | `go test -race ./...` plus `go vet ./...` |
| Web unit | components and hooks, Vitest + Testing Library, API mocked with MSW | beside the source in `web/src/` | `pnpm test` (and `pnpm typecheck`) |
| End to end | Playwright against the built binary with a fresh temp database: sign in, create, edit and delete a note, upload a photo, sign out, 404 page | `web/test/e2e/` | `make e2e` |

Shell scripts (deploy, backup pull, restore, generator preflight, the Claude hook, the
rename script and the build id script) have their own tests, run by `make test-scripts`.

## Commands

```sh
make test-fast                  # Go -short + Vitest + typecheck (seconds)
make test                       # Go -race + vet, Vitest, typecheck, generated-code check, script tests
make e2e-install                # once: downloads Chromium for Playwright
make e2e                        # builds the frontend and the binary, then runs Playwright
make test-scripts               # scripts/deploy.test.sh, gen-api preflight, hook test, rename test, build-id test, layout test
```

Web commands need Node 24 and pnpm through corepack (`corepack enable`, see `.nvmrc`).

## Skipped under `-short`

Integration tests in `web/api/tests/` call `integration(t)`, which skips them with `-short`,
so `make test-fast` stays quick. The tests that check the embedded migrations and frontend
(`TestEmbedded...`) and the import-direction guard run in every tier on purpose.
`TestEmbeddedAppPresentWhenBuilt` and the deep-link test skip locally when the frontend has not
been built, but **fail** when the `CI` environment variable is set, so CI can never skip them
silently (both CI Go jobs run `pnpm build` first).

## How end to end works

`web/test/e2e/global-setup.ts` builds the frontend (`pnpm build`, skipped with `E2E_SKIP_BUILD=1`
when it is already built) and the Go binary into a temp directory, creates a user with the
`user create` command in a fresh temp `DATA_DIR`, starts the server on a random free port and
waits for `/healthz`. Everything is removed afterwards. No test touches your real data.
The frontend build writes into `web/api/internal/web/app` (the embed directory), which is
shared with `make build`; the prebuild step clears it first, and it stays out of git.
This is not Vite's usual `dist/`: `go:embed` can only embed files inside the Go module. The repo-root
`dist/` holds only the binary from `make build`; e2e builds its own binary in a temp directory.

Failure artifacts (traces, screenshots, the HTML report) land in `web/test/e2e/test-results` and
`web/test/e2e/playwright-report`; both are gitignored.

## Adding a test

- **Go unit:** put `foo_test.go` next to `foo.go`. Use `internal/testutil` for a temp
  database and `httptest` for handlers. Table-driven tests, standard library only.
- **Go integration:** add a file in `web/api/tests/`, start with `integration(t)`, and boot the
  app through `internal/apptest`. Assert on real HTTP responses and on the database. Change the
  configuration with an option, e.g.
  `apptest.NewServer(t, apptest.WithConfig(func(c *config.Config) { c.TrustedProxy = "127.0.0.1/32" }))`.
- **Web unit:** add `Thing.test.tsx` beside the component. Render with `src/test/render.tsx`
  and add MSW handlers in `src/test/handlers.ts`. Query by role and label, as a user would.
- **End to end:** add `name.spec.ts` in `web/test/e2e/`. Use the helpers in `support.ts`. Keep it to
  journeys a browser must prove; push detail down to the cheaper tiers.
- **Shell scripts:** extend the matching `*.test.sh`; use fake commands on `PATH` and temp
  directories, never real servers. `ONLY='test_deploy_*' bash scripts/deploy.test.sh` runs a subset of the
  deploy, restore, pull and smoke tests (add new test names to the list at the bottom of the file).

`scripts/rename.test.sh` renames a copy of the repo, builds and tests it, and also runs the layout guard's
self-tests in that copy, so it is slow (about a minute); run it before merging, not on every edit. The
`deploy.test.sh` runner prints `SKIPPED: n` in its summary for tests that skipped themselves (for example the
plist lint when `plutil` is missing); a skip is counted, never silent, and does not fail the run.

Write the failing test first, watch it fail for the right reason, then implement.

## Tests that pin cross-cutting behavior

- `internal/server` `TestNewAppliesChain`: the middleware order in `server.New`. A cross-origin POST is
  refused with 403 and still carries the security headers and is request-logged with the forwarded
  client IP; an oversized body gets a JSON 413 with the headers; `X-Forwarded-For` counts only from the
  trusted peer. `TestAppNeverSendsHSTS`: the proxy owns HSTS.
- `internal/server` `TestWrapPanicOrder`, `TestRecover`, `TestRequestID` and `tests/recover_test.go`: a handler
  panic is a JSON 500 with `X-Request-Id`, security headers and a request log line (status 500, `request_id`);
  the order is TrustedProxy, RequestID, RequestLog, Recover, SecurityHeaders, SameOrigin, BodyLimit.
- `tests/proxy_throttle_test.go`: with `TRUSTED_PROXY` set, sign-in failures are throttled per forwarded
  client address; without it the header is ignored.
- `tests/contract_errors_test.go`: every mutating operation's cross-origin 403 and the global 413 are
  `Error` JSON, as `openapi.yaml` declares.
- `cmd/goweb`: `user create` and `backup` create owner-only files under umask 0
  (`umask_test.go`); development mode logs a warning when it listens beyond loopback (`serve_test.go`);
  `backup --label` (`backup_test.go`).
- `internal/config`: `PUBLIC_ORIGIN` normalization and rejection rules, and the production refusal messages.
- `internal/backup/label_test.go`: labeled sets, per-label pruning in both directions, label validation.
- `internal/app`: expired-session purge at start and on every tick (`maintenance_test.go`) and the
  start-up sweep of stale upload temp files.
- `scripts/deploy.test.sh`: `deploy.sh` refuses a non-production server `.env` (and `--check` reports it) unless
  `ALLOW_DEV_DEPLOY=1`, uses a `predeploy` labeled backup, and explains a missing user unit; `restore.sh`
  accepts a labeled set; `pull-backups.sh` ignores labeled sets for copying, `KEEP` and staleness.

- `internal/db` `migrate_test.go`: a checksum is over the exact bytes; every `*.sql` must be named
  `NNNN_description.sql` (`^[0-9]{4}_[a-z0-9_]+\.sql$`) and two files may not share a version (the error names
  the file and nothing is applied); gaps in the numbering are fine; several goroutines upgrading a
  database from before the checksum column all succeed and record each checksum once (run under `-race`).
  A recorded migration whose file is gone from the binary is not verified (a rolled-back binary keeps working).
  `.gitattributes` marks `*.sql` as `-text`, so autocrlf cannot change the bytes; `layout.test.sh` asserts it.
- `scripts/deploy.test.sh` deploy gate: the backup timer has three outcomes (enabled; not enabled; could not
  determine because ssh or the user bus failed, which refuses with `REQUIRE_BACKUP_TIMER=1` and otherwise
  warns); the gate runs `go vet` and `go test -short` in `web/api` without the caller's `GOOS`/`GOARCH`; the
  Node check compares majors for `v24`, `24`, `24.1.0` and `v24.18.0` and skips a non-numeric `.nvmrc` such as
  `lts/*` with a message; after the restart a missing `ss` and an ssh failure are reported as such, not as a
  closed port. The fakes record the unit name and working directory they are called with.
- `scripts/deploy.test.sh` backup agent: reinstall waits for `bootout` to finish and retries `bootstrap` on an
  I/O error (fake `launchctl`), `--uninstall` with nothing installed says "nothing installed", `--dry-run` changes
  nothing; idempotence is asserted on call content, not call positions.

## Endpoint guard rails

`web/api/tests/guardrails_test.go` keeps the API, its spec and its tests in step. It runs in the fast
tier too (a file scan, no server). Adding an endpoint means doing all three, or `make test-fast` says
which one is missing:

1. Register the route with a literal `"METHOD /path"` pattern (`mux.HandleFunc("GET /api/things/{id}", ...)`).
   A route in code but not in `web/api/openapi.yaml`, or the reverse, fails
   `TestSpecAndRegisteredRoutesMatch`.
2. Declare it in `openapi.yaml` with an `operationId`, then run `make api`.
3. Write the integration test that exercises it and mark it with `// covers: <operationId>` (several ids
   may share a comment). An operation no test claims fails `TestEveryOperationHasAnIntegrationTest`,
   as does a `covers:` naming an operationId that no longer exists. Copy `notes_flow_test.go`.

**Private by default.** `server.New` mounts every `/api/` path that is not explicitly public behind
`auth.Require`, so a new route cannot be public by accident. `TestAPIIsPrivateByDefault` (integration tier) sends
a signed-out request to every `/api/` route found in the spec AND registered in Go that is not in the one allowlist,
`publicRoutes` in `guardrails_test.go` (login, logout, getMe and healthz today), and expects 401; an unknown
`/api/zzz-not-a-route` is 401 signed out and 404 signed in. `TestPublicAllowlistMatchesTheSpec` keeps the allowlist
and the spec in step: every public route is in the spec, carries `security: []` (getMe is the one listed route that
stays secured in the spec, because it answers 401 itself), and no other operation has `security: []`. To make an
endpoint public, add it to `publicRoutes` with a reason, register it explicitly in `server.New`, and mark it
`security: []` in `openapi.yaml`. To check the guard, temporarily register an extra unwrapped
`mux.HandleFunc("GET /api/x", ...)` in `server.New` and watch the test fail. A method-less mount such as
`mux.HandleFunc("/api/admin", ...)` is invisible to the spec-drift test and to the probe, so
`TestServerMountsNothingPublicUnderAPI` scans the `"/api/..."` string literals of `internal/server/server.go` and
fails on any that is not public, the `/api/` catch-all or on the `private` mux. The scan ignores comments (a trailing comment mentioning `private.` does not exempt a mount) and sees both
`"..."` and backtick literals. Remaining limit: it reads literals in
that one file; a path built by concatenation (`prefix+"/x"`), a route mounted through a variable, or one registered from another file escapes it (the probe still catches one that is
in the spec or has a literal `"METHOD /path"` pattern).

The spec is read by its indentation (paths at two spaces, methods at four, `operationId` at six) because
the module has no YAML library; a differently laid-out spec makes the guard fail loudly, not pass.

## Repository layout

- `scripts/layout.test.sh`: `deploy/` holds no `*.sh` (only files installed on a server: units and the NGINX
  example), the deploy, smoke, restore and pull-backups scripts and `deploy.test.sh` are in `scripts/`, every
  test script ends in `.test.sh`, Playwright is in `web/test/e2e/` (the old e2e directory directly under `web/` is gone), `node_modules/` and
  the e2e output directories are ignored at any depth, no tracked file is ignored, and no tracked file names
  an old location: the old e2e directory, a deploy script addressed through `deploy/`
  (by path, glob, `cd`, `bash`, `./` or `../`), or a bare script name on a line that mentions `deploy/` without
  `scripts/`. `.gitattributes` must mark `*.sql` as `-text`. The `deploy/` self-tests (an extra and a missing
  file) require the failure to come from the `deploy/` check itself, not from any other check.
  **Host mode:** when `.goweb-origin` exists at the root (the `new-web-app` wrapper writes it when it turns goweb
  into an app) the app may live inside a host repo with its own `ios/` and root `CLAUDE.md`. The guard then
  skips only the starter-only checks (the `ios/` placeholder and goweb's own root `CLAUDE.md` headings) and exempts the
  `### Done` section of EACH of root `CLAUDE.md` and `web/CLAUDE.md` that has one (the host's own log and goweb's
  moved log, which the wrapper puts at `web/CLAUDE.md` when the host already has a root one; a section runs to the
  next `## ` or `### ` heading or the end of the file). The rest of both files is current-state text and stays checked.
  If `.goweb-origin` exists but `README.md` still starts with `# goweb`, the guard fails loudly: the marker is for
  apps created from the starter, not for the starter itself (a CRLF README title counts too).
  The self-tests that build host fixtures from the starter's own layout run in the starter only; in an app created
  from it (marker present) they print `SKIPPED: starter-only self-tests (host mode)` and the summary ends with a
  `SKIPPED: n` total. The starter instead builds a host-shaped app in a throwaway copy (renamed to `shop`, no
  `ios/README.md`, a host root `CLAUDE.md` with its own log, goweb's log at `web/CLAUDE.md`, tracked marker) and runs
  the FULL guard in it: it must pass, and the same app with a stale path outside the Done sections must fail.
  Every structural check (`scripts/`, `deploy/`, Playwright location, ignores, `.gitattributes`, stale paths)
  stays on. Without `.goweb-origin` goweb itself is fully guarded. The self-tests build a host layout in a
  throwaway copy: it passes with `.goweb-origin`, still fails without it (naming the `ios/` and `CLAUDE.md`
  problems), and a stale path in `web/CLAUDE.md` outside the Done section still fails.
  `docs/superpowers/` (historical specs) and the dated entries under `### Done` in `CLAUDE.md` (history,
  between the `### Done` and `### Not yet verified` headings) are exempt; the rest of `CLAUDE.md` is
  current-state text and is checked. The test also proves the guard works: it injects each stale pattern into
  a throwaway copy of the tracked files and expects a failure, and expects the legitimate lookalikes
  (`scripts/deploy.sh`, `../deploy/nginx.conf.example`, `/home/deploy/...`) to pass.

## Build id

- `scripts/build-id.test.sh`: temp git repos for a clean tree, a modified tracked file (`-dirty`),
  untracked-only files (stay clean), no git, no commits (`unknown`), `BUILD_DATE`, `SOURCE_DATE_EPOCH`
  (UTC, BSD and GNU `date`) and the output format.
- `internal/version`: the default id is well formed. `internal/web`: every page source under `pages/`
  holds the `@@BUILD_ID@@` placeholder exactly once (a new page cannot forget it) and sits in a
  `site-footer`; served pages, the 404 and the 503 pages show `Build <id>` (the 404 and 503 keep a
  `Content-Length` and no ETag); `/static/` files, nested ones included, are served unmodified; the app's `index.html`
  is served with `__BUILD_ID__` replaced, a matching `Content-Length`, an ETag that follows the id,
  other app files untouched, and the id HTML-escaped. `internal/server`: `/healthz` reports `build_id`.
- `tests/public_test.go` `TestEveryPageFooterShowsTheHealthzBuildID`: `/`, `/faq`, `/privacy`, `/terms`,
  `/support`, a 404 URL and (when the app is built; a failure under `CI`) `/app/` show the id that
  `/healthz` reports.
- `src/Footer.test.tsx`: the React footer reads the meta tag, shows `dev` for the placeholder or a
  missing tag, and is on the sign-in, notes and not-found routes.
- `web/test/e2e/buildid.spec.ts`: a real id (from `scripts/build-id.sh`) in `/healthz` and in the footer of `/`,
  the sign-in page, the notes page and the 404 page.
- `scripts/deploy.test.sh`: `smoke.sh` accepts a matching footer and fails on a footer id that differs from
  `/healthz`, a missing footer, a missing or malformed `build_id` and a wrong `EXPECTED_BUILD_ID`;
  `deploy.sh` passes the same id to its build ldflags and to the smoke run.

## Import-direction guard

`web/api/tests/boundary_test.go` parses the Go imports under `web/api/internal` and fails
when the layering is broken: handlers and stores (`notes`, `auth`, `storage`, `backup`,
`web`, `logging`) never import `server`, `app` or `apptest`; the leaf packages (`db`,
`config`, `uid`, `version`, `apigen`) import no feature package; `auth` does not know about
`notes`; `notes` does not import `db` (it gets a `*sql.DB` injected); the test harness and
`testutil` are never imported by production code. If a new package needs an exception, change the rule table in that
file deliberately, in its own commit.

## Generated code

`make api` regenerates `web/api/internal/apigen/models.gen.go` and `web/src/api/schema.d.ts`
from `web/api/openapi.yaml`. `scripts/gen-api.test.sh` (part of `make test`) fails when
regenerating changes either file or the lockfile; the CI `full` job fails when regenerating leaves
any change at all in `git status --porcelain`, including new untracked files.

## What is not covered

- A real SSH deploy, a real systemd user service, the real `rrsync` gate and `mv -T` on
  Linux: the scripts are tested against fakes.
- Browsers other than Chromium, and Windows.
- The OpenAPI contract against a second client.
- Load, soak and security scanning.
- A restore drill against a real server (the drill passes in the automated tests).
