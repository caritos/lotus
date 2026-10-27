# Testing

Four tiers, from the quickest to the most realistic. The fast tier is the inner loop; the
full tier runs before every merge; end to end is separate because it downloads a browser.

| Tier | What | Where | Command |
|---|---|---|---|
| Go unit | package logic, handlers with `httptest`, in-memory or temp-file SQLite | beside the code (`foo_test.go`) | `go test -short ./...` |
| Go integration | real server wiring, migrations on populated data, auth flow, upload to `storage/`, backup and restore round trip, embed and import-direction checks | `web/api/tests/` | `go test -race ./...` plus `go vet ./...` |
| Web unit | components and hooks, Vitest + Testing Library, API mocked with MSW | beside the source in `web/src/` | `pnpm test` (and `pnpm typecheck`) |
| End to end | Playwright against the built binary with a fresh temp database: sign in, create, edit and delete a note, upload a photo, sign out, 404 page | `web/e2e/` | `make e2e` |

Shell scripts (deploy, backup pull, restore, generator preflight, the Claude hook and the
rename script) have their own tests, run by `make test-scripts`.

## Commands

```sh
make test-fast                  # Go -short + Vitest + typecheck (seconds)
make test                       # Go -race + vet, Vitest, typecheck, generated-code check, script tests
make e2e-install                # once: downloads Chromium for Playwright
make e2e                        # builds the frontend and the binary, then runs Playwright
make test-scripts               # deploy/test.sh, gen-api preflight, hook test, rename test
```

Web commands need Node 24 and pnpm through corepack (`corepack enable`, see `.nvmrc`).

## Skipped under `-short`

Integration tests in `web/api/tests/` call `integration(t)`, which skips them with `-short`,
so `make test-fast` stays quick. The tests that check the embedded migrations and frontend
(`TestEmbedded...`) and the import-direction guard run in every tier on purpose.
`TestEmbeddedAppPresentWhenBuilt` skips when the frontend has not been built; in CI it runs
after `pnpm build`.

## How end to end works

`web/e2e/global-setup.ts` builds the frontend (`pnpm build`, skipped with `E2E_SKIP_BUILD=1`
when it is already built) and the Go binary into a temp directory, creates a user with the
`user create` command in a fresh temp `DATA_DIR`, starts the server on a random free port and
waits for `/healthz`. Everything is removed afterwards. No test touches your real data.
The frontend build writes into `web/api/internal/web/app` (the embed directory), which is
shared with `make build`; the prebuild step clears it first, and it stays out of git.

Failure artifacts (traces, screenshots, the HTML report) land in `web/e2e/test-results` and
`web/e2e/playwright-report`; both are gitignored.

## Adding a test

- **Go unit:** put `foo_test.go` next to `foo.go`. Use `internal/testutil` for a temp
  database and `httptest` for handlers. Table-driven tests, standard library only.
- **Go integration:** add a file in `web/api/tests/`, start with `integration(t)`, and boot the
  app through `internal/apptest`. Assert on real HTTP responses and on the database.
- **Web unit:** add `Thing.test.tsx` beside the component. Render with `src/test/render.tsx`
  and add MSW handlers in `src/test/handlers.ts`. Query by role and label, as a user would.
- **End to end:** add `name.spec.ts` in `web/e2e/`. Use the helpers in `support.ts`. Keep it to
  journeys a browser must prove; push detail down to the cheaper tiers.
- **Shell scripts:** extend the matching `*.test.sh`; use fake commands on `PATH` and temp
  directories, never real servers.

Write the failing test first, watch it fail for the right reason, then implement.

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
from `web/api/openapi.yaml`. `scripts/gen-api.test.sh` (part of `make test`) and the CI `full`
job fail when regenerating changes either file or the lockfile.

## What is not covered

- A real SSH deploy, a real systemd user service, the real `rrsync` gate and `mv -T` on
  Linux: the scripts are tested against fakes.
- Browsers other than Chromium, and Windows.
- The OpenAPI contract against a second client.
- Load, soak and security scanning.
- A restore drill against a real server (the drill passes in the automated tests).
