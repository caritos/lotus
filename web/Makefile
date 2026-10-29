VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
COMMIT  ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
# Run from web/ (cd web && make test, or make -C web test). BUILD_ID is YYYYMMDD-<short commit> (see scripts/build-id.sh); computed once per make run.
BUILD_ID := $(shell bash "$(CURDIR)/scripts/build-id.sh")
LDFLAGS := -X app/internal/version.Version=$(VERSION) -X app/internal/version.Commit=$(COMMIT) -X app/internal/version.BuildID=$(BUILD_ID)

.PHONY: help dev build test-fast test test-scripts test-skills test-api e2e e2e-install api

help:
	@echo "make dev          Go API on 127.0.0.1:8080 plus the Vite dev server on :5173"
	@echo "make build        build the frontend, then the single binary dist/app"
	@echo "make test-fast    fast tier: go test -short, Vitest, typecheck"
	@echo "make test         full tier: go test -race, go vet, Vitest, typecheck, generated-code check, script tests"
	@echo "make test-scripts shell tests: deploy, generator preflight, hook, rename, build id, layout"
	@echo "make test-skills   fast tier of the new-web-app and new-ios-app skill tests (skipped where .claude/skills is absent; the new-ios-app tier needs xcodegen and swift)"
	@echo "make e2e-install  download Chromium for Playwright (once)"
	@echo "make e2e          Playwright against the built binary"
	@echo "make api          regenerate Go models and the TypeScript schema from web/api/openapi.yaml"

# Go API on 127.0.0.1:8080 (data under web/) plus the Vite dev server on :5173; Ctrl-C stops both.
# It sets its own environment; deploy/.env.example is the server template and is not used here.
dev:
	@bash scripts/sync-public.sh; \
	trap 'kill 0' INT TERM EXIT; \
	(cd api && DATA_DIR=.. ADDR=127.0.0.1:8080 PUBLIC_ORIGIN=http://localhost:5173 APP_ENV=development go run -ldflags "-X app/internal/version.BuildID=$(BUILD_ID)" ./cmd/app serve) & \
	pnpm dev & \
	wait

build:
	bash scripts/sync-public.sh
	pnpm install --frozen-lockfile && pnpm build
	mkdir -p dist
	cd api && go build -ldflags "$(LDFLAGS)" -o ../dist/app ./cmd/app

test-fast:
	bash scripts/sync-public.sh
	cd api && go test -short ./...
	pnpm test && pnpm typecheck

test:
	@bash scripts/sync-public.sh >/dev/null
	@cd api && test -z "$$(gofmt -l .)" || { echo "gofmt needed on:"; gofmt -l .; exit 1; }
	cd api && go test -race ./... && go vet ./...
	pnpm test && pnpm typecheck
	bash scripts/gen-api.test.sh
	$(MAKE) test-scripts
	$(MAKE) test-skills

# Shell tests for the deploy, generator, hook, rename, build-id and layout scripts (need sqlite3 and go).
test-scripts:
	bash scripts/deploy.test.sh
	bash scripts/gen-api-preflight.test.sh
	bash ../.claude/hooks/post-edit.test.sh
	bash scripts/rename.test.sh
	bash scripts/build-id.test.sh
	bash scripts/sync-public.test.sh
	bash scripts/layout.test.sh

# Fast tier of the new-web-app skill tests (a fixture stands in for the starter). A project started from
# this repo has no .claude/skills, so the target does nothing there. Full tier: see docs/testing.md.
test-skills:
	@if [ -f ../.claude/skills/new-web-app/tests/run.sh ]; then \
	  bash ../.claude/skills/new-web-app/tests/run.sh --fast || exit 1; \
	  bash ../.claude/skills/new-ios-app/tests/makefile-skip.test.sh || exit 1; \
	  if command -v xcodegen >/dev/null 2>&1 && command -v swift >/dev/null 2>&1; then \
	    bash ../.claude/skills/new-ios-app/tests/scaffold.test.sh --fast || exit 1; \
	  else echo "skipped new-ios-app tests: xcodegen or swift not installed"; fi; \
	else echo "test-skills: no .claude/skills here, nothing to run"; fi

test-api:
	bash scripts/gen-api.test.sh

# Playwright against the built binary (not part of test/test-fast; needs `make e2e-install` once).
e2e:
	pnpm exec playwright test -c test/e2e/playwright.config.ts

e2e-install:
	pnpm exec playwright install chromium

api:
	bash scripts/gen-api.sh
