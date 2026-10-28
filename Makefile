VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
COMMIT  ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
# BUILD_ID is YYYYMMDD-<short commit> (see scripts/build-id.sh); computed once per make run.
BUILD_ID := $(shell bash "$(CURDIR)/scripts/build-id.sh")
LDFLAGS := -X goweb/internal/version.Version=$(VERSION) -X goweb/internal/version.Commit=$(COMMIT) -X goweb/internal/version.BuildID=$(BUILD_ID)

.PHONY: help dev build test-fast test test-scripts test-api e2e e2e-install api

help:
	@echo "make dev          Go API on 127.0.0.1:8080 plus the Vite dev server on :5173"
	@echo "make build        build the frontend, then the single binary ./goweb"
	@echo "make test-fast    fast tier: go test -short, Vitest, typecheck"
	@echo "make test         full tier: go test -race, go vet, Vitest, typecheck, generated-code check, script tests"
	@echo "make test-scripts shell tests: deploy, generator preflight, hook, rename, build id"
	@echo "make e2e-install  download Chromium for Playwright (once)"
	@echo "make e2e          Playwright against the built binary"
	@echo "make api          regenerate Go models and the TypeScript schema from web/api/openapi.yaml"

# Go API on 127.0.0.1:8080 (data under web/) plus the Vite dev server on :5173; Ctrl-C stops both.
# It sets its own environment; .env.example is the server template and is not used here.
dev:
	@trap 'kill 0' INT TERM EXIT; \
	(cd web/api && DATA_DIR=.. ADDR=127.0.0.1:8080 PUBLIC_ORIGIN=http://localhost:5173 APP_ENV=development go run -ldflags "-X goweb/internal/version.BuildID=$(BUILD_ID)" ./cmd/goweb serve) & \
	(cd web && pnpm dev) & \
	wait

build:
	cd web && pnpm install --frozen-lockfile && pnpm build
	cd web/api && go build -ldflags "$(LDFLAGS)" -o ../../goweb ./cmd/goweb

test-fast:
	cd web/api && go test -short ./...
	cd web && pnpm test && pnpm typecheck

test:
	@cd web/api && test -z "$$(gofmt -l .)" || { echo "gofmt needed on:"; gofmt -l .; exit 1; }
	cd web/api && go test -race ./... && go vet ./...
	cd web && pnpm test && pnpm typecheck
	bash scripts/gen-api.test.sh
	$(MAKE) test-scripts

# Shell tests for the deploy, generator, hook, rename and build-id scripts (need sqlite3 and go).
test-scripts:
	bash deploy/test.sh
	bash scripts/gen-api-preflight.test.sh
	bash .claude/hooks/post-edit.test.sh
	bash scripts/rename.test.sh
	bash scripts/build-id.test.sh

test-api:
	bash scripts/gen-api.test.sh

# Playwright against the built binary (not part of test/test-fast; needs `make e2e-install` once).
e2e:
	cd web && pnpm exec playwright test -c e2e/playwright.config.ts

e2e-install:
	cd web && pnpm exec playwright install chromium

api:
	bash scripts/gen-api.sh
