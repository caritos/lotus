# web/test

What lives where for the web app's tests:

- `e2e/`: Playwright end-to-end tests against the built binary (specs, `global-setup.ts`,
  `playwright.config.ts`, `fixtures/`). Failure artifacts land in `e2e/test-results/` and
  `e2e/playwright-report/` (both gitignored).
- Vitest unit and component tests are not here: they sit beside the source files in `web/src/`
  (`*.test.ts`, `*.test.tsx`).

Run, from `web/`:

```sh
make e2e-install   # download Chromium once
make e2e           # build the binary, start it on a free port with a temp database, run the specs
```

Unit tests: `pnpm test`. Typecheck (app and e2e): `pnpm typecheck`.

The Playwright tests stay in `web/test/e2e/` (not under `web/scripts/`): `web/test/` is where every web-platform test tree that is not a unit test sits, and `web/scripts/layout.test.sh` guards it.
