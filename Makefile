VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
COMMIT  ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
LDFLAGS := -X goweb/internal/version.Version=$(VERSION) -X goweb/internal/version.Commit=$(COMMIT)

.PHONY: dev build test-fast test e2e api

dev:
	@echo "not implemented yet (Task 8)"; exit 1

build:
	@if [ -f web/package.json ]; then cd web && pnpm install --frozen-lockfile && pnpm build; \
	else echo "skipping web build: web/package.json not found (frontend arrives in a later task)"; fi
	cd web/api && go build -ldflags "$(LDFLAGS)" -o ../../goweb ./cmd/goweb

test-fast:
	cd web/api && go test -short ./...

test:
	cd web/api && go test -race ./... && go vet ./...

e2e:
	@echo "not implemented yet (Task 11)"; exit 1

api:
	@echo "not implemented yet (Task 4)"; exit 1
