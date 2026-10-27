#!/usr/bin/env bash
# Regenerates the Go models and the TypeScript schema from web/api/openapi.yaml.
set -euo pipefail

OAPI_CODEGEN_VERSION="v2.8.0"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
spec="$root/web/api/openapi.yaml"

cd "$root/web/api"
go run "github.com/oapi-codegen/oapi-codegen/v2/cmd/oapi-codegen@${OAPI_CODEGEN_VERSION}" \
  -config oapi-codegen.yaml openapi.yaml
echo "generated web/api/internal/apigen/models.gen.go (oapi-codegen ${OAPI_CODEGEN_VERSION})"

cd "$root/web"
mkdir -p src/api
pnpm install --frozen-lockfile >/dev/null
pnpm exec openapi-typescript "$spec" -o src/api/schema.d.ts
echo "generated web/src/api/schema.d.ts (openapi-typescript)"
