#!/usr/bin/env bash
# Rename the starter: scripts/rename.sh [--force] [--regen] <module-path> <name>
#
#   <module-path>  Go module path, e.g. github.com/acme/shop
#   <name>         lowercase letters and digits, e.g. shop: binary, cookie, unit and database names
#
# Rewrites tracked text files only (never .git, node_modules, docs/superpowers, pnpm-lock.yaml
# or binary files), then renames files whose path contains "goweb" with git mv.
# Refuses to run outside a git work tree or with uncommitted changes unless --force.
# --regen also runs scripts/gen-api.sh (the text replacement already keeps the generated
# files consistent, so this is optional).
set -euo pipefail

OLD="goweb"
OLD_UPPER="GOWEB"

die() { echo "rename: $*" >&2; exit 1; }
usage() { echo "usage: scripts/rename.sh [--force] [--regen] <module-path> <name>" >&2; exit 2; }

FORCE=0; REGEN=0; ARGS=()
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    --regen) REGEN=1 ;;
    --*) usage ;;
    *) ARGS+=("$a") ;;
  esac
done
[ "${#ARGS[@]}" -eq 2 ] || usage
MODULE="${ARGS[0]}"
NAME="${ARGS[1]}"

MODULE_RE='^[a-z0-9][a-z0-9._-]*(/[A-Za-z0-9._-]+)*$'
NAME_RE='^[a-z][a-z0-9]*$'
[[ "$MODULE" =~ $MODULE_RE ]] || die "invalid module path '$MODULE': use lowercase letters, digits, '.', '_' and '-', with '/' separated segments (for example github.com/acme/shop)"
[[ "$NAME" =~ $NAME_RE ]] || die "invalid name '$NAME': use a lowercase letter followed by lowercase letters and digits only (for example shop)"

if [ "$MODULE" = "$OLD" ] && [ "$NAME" = "$OLD" ]; then
  echo "rename: module path and name are already '$OLD'; nothing to do."
  exit 0
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$here/.." && pwd)"
cd "$ROOT"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git work tree: run this in a clone of the starter"
[ "$(git rev-parse --show-toplevel)" = "$(pwd -P)" ] || die "this script must live in the root of its own git work tree"
if [ "$FORCE" -ne 1 ] && [ -n "$(git status --porcelain)" ]; then
  die "uncommitted changes found: commit or stash them first (or pass --force)"
fi

NAME_UPPER="$(printf '%s' "$NAME" | tr '[:lower:]' '[:upper:]')"
TOKEN="@@RENAME_MODULE_PATH@@"

excluded() {
  case "$1" in
    docs/superpowers/*|*/node_modules/*|web/pnpm-lock.yaml|pnpm-lock.yaml|.git/*) return 0 ;;
  esac
  return 1
}

CHANGED=0
while IFS= read -r -d '' f; do
  excluded "$f" && continue
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  grep -Iq . "$f" 2>/dev/null || continue            # binary or empty
  grep -q -e "$OLD" -e "$OLD_UPPER" "$f" 2>/dev/null || continue
  # Module path first (parked behind a token so a module path that contains "goweb" survives
  # the word replacement), then the word itself.
  OLD_W="$OLD" OLD_U="$OLD_UPPER" NEW_W="$NAME" NEW_U="$NAME_UPPER" TOK="$TOKEN" \
    perl -pi -e '
      BEGIN { $o=$ENV{OLD_W}; $ou=$ENV{OLD_U}; $n=$ENV{NEW_W}; $nu=$ENV{NEW_U}; $t=$ENV{TOK}; }
      s{^module \Q$o\E$}{module $t}m;
      s{(?<![\w./~-])\Q$o\E/(internal|cmd|tests)\b}{$t/$1}g;
      s{\Q$ou\E}{$nu}g;
      s{\Q$o\E}{$n}g;
    ' "$f"
  MODULE="$MODULE" TOK="$TOKEN" perl -pi -e 'BEGIN { $m=$ENV{MODULE}; $t=$ENV{TOK}; } s{\Q$t\E}{$m}g' "$f"
  CHANGED=$((CHANGED+1))
done < <(git ls-files -z)

# Rename paths that contain the old name.
MOVED=0
while IFS= read -r -d '' f; do
  excluded "$f" && continue
  case "$f" in *"$OLD"*) ;; *) continue ;; esac
  new="${f//$OLD/$NAME}"
  mkdir -p "$(dirname "$new")"
  git mv "$f" "$new"
  rmdir "$(dirname "$f")" 2>/dev/null || true   # drop the emptied old directory
  MOVED=$((MOVED+1))
done < <(git ls-files -z)

if [ "$REGEN" -eq 1 ]; then
  bash scripts/gen-api.sh
fi

echo "rename: module '$MODULE', name '$NAME': $CHANGED files rewritten, $MOVED files moved."
left="$(git ls-files -z | { while IFS= read -r -d '' f; do excluded "$f" && continue; [ -f "$f" ] || continue; grep -Iq -e "$OLD" -e "$OLD_UPPER" "$f" 2>/dev/null && echo "$f"; done; } || true)"
if [ -n "$left" ]; then
  echo "rename: WARNING, the old name still appears in:" >&2
  echo "$left" >&2
else
  echo "rename: no occurrence of '$OLD' remains outside docs/superpowers."
fi
cat <<NEXT

Next steps:
  - update the README title and the public page copy (web/api/internal/web/pages/)
  - add a LICENSE of your choice
  - on the server, create .env from .env.example and set SESSION_SECRET and PUBLIC_ORIGIN
  - point the git remote at your repository: git remote set-url origin <url>
  - run: make test
NEXT
