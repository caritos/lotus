VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
COMMIT  ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
LDFLAGS := -X goweb/internal/version.Version=$(VERSION) -X goweb/internal/version.Commit=$(COMMIT)

.PHONY: dev build test-fast test test-api e2e e2e-install api

# Go API on :8080 (data under web/) plus the Vite dev server on :5173; Ctrl-C stops both.
dev:
	@trap 'kill 0' INT TERM EXIT; \
	(cd web/api && DATA_DIR=.. PUBLIC_ORIGIN=http://localhost:5173 APP_ENV=development go run ./cmd/goweb serve) & \
	(cd web && pnpm dev) & \
	wait

build:
	@if [ -f web/package.json ]; then cd web && pnpm install --frozen-lockfile && pnpm build; \
	else echo "skipping web build: web/package.json not found (frontend arrives in a later task)"; fi
	cd web/api && go build -ldflags "$(LDFLAGS)" -o ../../goweb ./cmd/goweb

test-fast:
	cd web/api && go test -short ./...
	cd web && pnpm test && pnpm typecheck

test:
	cd web/api && go test -race ./... && go vet ./...
	cd web && pnpm test && pnpm typecheck
	bash scripts/gen-api.test.sh

test-api:
	bash scripts/gen-api.test.sh

# Playwright against the built binary (not part of test/test-fast; needs `make e2e-install` once).
e2e:
	cd web && pnpm exec playwright test -c e2e/playwright.config.ts

e2e-install:
	cd web && pnpm exec playwright install chromium

api:
	bash scripts/gen-api.sh
