#!/usr/bin/env bash
# Regenerates the Go models and the TypeScript schema from web/api/openapi.yaml.
set -euo pipefail

OAPI_CODEGEN_VERSION="v2.8.0"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
spec="$root/web/api/openapi.yaml"

die() { echo "gen-api: $*" >&2; exit 1; }

command -v go >/dev/null 2>&1 || die "go is not installed or not on PATH (see web/api/go.mod for the required version)"
command -v pnpm >/dev/null 2>&1 || die "pnpm not found on PATH: use Node 24 (see web/.nvmrc) and run 'corepack enable'"

cd "$root/web/api"
go run "github.com/oapi-codegen/oapi-codegen/v2/cmd/oapi-codegen@${OAPI_CODEGEN_VERSION}" \
  -config oapi-codegen.yaml openapi.yaml \
  || die "step 'go run oapi-codegen@${OAPI_CODEGEN_VERSION}' failed: check network access (the module is downloaded on first use) and web/api/openapi.yaml"
echo "generated web/api/internal/apigen/models.gen.go (oapi-codegen ${OAPI_CODEGEN_VERSION})"

cd "$root/web"
mkdir -p src/api
install_log="$(mktemp)"
if ! pnpm install --frozen-lockfile >"$install_log" 2>&1; then
  cat "$install_log" >&2; rm -f "$install_log"
  die "step 'pnpm install --frozen-lockfile' failed: check network access and that web/pnpm-lock.yaml matches web/package.json"
fi
rm -f "$install_log"
pnpm exec openapi-typescript "$spec" -o src/api/schema.d.ts \
  || die "step 'openapi-typescript' failed: check web/api/openapi.yaml and that dependencies are installed"
echo "generated web/src/api/schema.d.ts (openapi-typescript)"
