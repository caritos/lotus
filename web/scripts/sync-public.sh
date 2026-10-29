#!/usr/bin/env bash
# Copies web/public/{pages,static} into web/api/embed/, the go:embed source (the React bundle goes to
# web/api/embed/spa/ from `pnpm build`; this script leaves it alone).
# go:embed cannot reach outside the Go module, so the frontend files live in web/public and
# this generated, gitignored copy sits inside web/api. Run it before anything that compiles or
# tests the Go module (every make target, deploy.sh, CI and the e2e harness do). Plain bash and
# cp: no Node, so the Go-only tiers can use it.
# Usage: bash web/scripts/sync-public.sh
set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB="$(cd "$HERE/.." && pwd)"
SRC="$WEB/public"
DEST="$WEB/api/embed"

for d in pages static; do
  if [ ! -d "$SRC/$d" ]; then
    echo "sync-public: web/public/$d is missing; nothing copied" >&2
    exit 1
  fi
done

mkdir -p "$DEST"
# Remove only what this script produces, so deleted source files do not linger and spa/ survives.
for d in pages static; do rm -rf "${DEST:?}/$d"; done
[ -e "$DEST/.gitkeep" ] || : > "$DEST/.gitkeep"

for d in pages static; do
  cp -R "$SRC/$d" "$DEST/$d"
  echo "sync-public: copied web/public/$d ($(find "$DEST/$d" -type f | wc -l | tr -d ' ') files) to web/api/embed/$d"
done
