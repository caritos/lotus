#!/usr/bin/env bash
# Rename the starter: web/scripts/rename.sh [--check] [--force] [--regen] <module-path> <name>
#
# --check runs every validation (name pattern, reserved words, the run-time reversibility check, module
# path) without modifying anything and without requiring a clean tree: exit 0 when the rename would be
# accepted, else the same error and a nonzero exit. Call it before staging a rename; do not copy the lists.
#
#   <module-path>  Go module path, e.g. github.com/acme/shop
#   <name>         lowercase letters and digits, e.g. shop: binary, cookie, unit and database names
#
# The CURRENT module path and name are read from the repository (web/api/go.mod and the single
# directory under web/api/cmd/), so the script works for any starting name, including the generic
# one the starter ships with. Because the shipped name is also an ordinary word (and a directory,
# a package and a URL prefix), the script never replaces the bare word. It replaces the name only
# in the contexts where it is the project name. A name is refused when it is a reserved word (a
# directory or variable word of the repository, see RESERVED: a fast pre-filter only) or, decisive,
# when the run-time check finds that the name already occurs in the tree in a context the rules
# rewrite: renaming back would then not be exact. Every name the check accepts can be renamed away
# from, and back, byte for byte (rename.test.sh proves this for several names).
# The contexts:
#
#   - the Go module path (module line, imports, -X ldflags), as `<module>/internal|cmd|tests`
#   - after a path prefix: cmd/, dist/, current/, releases/<v>/, ~/, $HOME/, %h/, /opt/,
#     /home/deploy/, Backups/, $VAR/, and as the deploy defaults (REMOTE_BASE, SERVICE, APP_NAME)
#   - launchd and logs: the label com.<name>.<job>, ~/.config/<name>/, ~/Library/Logs/<name>/,
#     backups/<name>, and the process name in an `ss -p` users:(("<name>",...)) field
#   - before an identifier suffix: <name>.db, .log, .service, .example, -backup, -pull, -e2e,
#     -web, -development-only, _session
#   - as the command: `<name> backup|serve|user|verify-backup|schema-version`, `usage: <name> `
#   - in systemd and nginx stanzas (Description=, User=, Group=, upstream, -u, systemctl --user)
#   - the env vars <NAME>_BIN and <NAME>_AUTH_PANIC_CHILD (not the shared APP_ENV; the APP_NAME variable stays, its default is renamed)
#   - the page <title>, brand link, <h1> and "What is <name>?" heading of the HTML pages
#
# Prose that merely mentions the name is NOT rewritten; edit the README and page copy by hand.
# Paths are moved only for web/api/cmd/<name>/ and web/deploy/<name>*; internal/app, web/api/embed
# and the /app/ URL mount are never touched. Rewrites tracked text files only (never .git,
# node_modules, docs/superpowers, .claude/skills, pnpm-lock.yaml, this script and its test, or binary files). Refuses to run outside a git
# work tree or with uncommitted changes unless --force.
# --regen also runs web/scripts/gen-api.sh (the text replacement already keeps the generated
# files consistent, so this is optional).
set -euo pipefail

die() { echo "rename: $*" >&2; exit 1; }
usage() { echo "usage: web/scripts/rename.sh [--check] [--force] [--regen] <module-path> <name>" >&2; exit 2; }

FORCE=0; REGEN=0; CHECK=0; ARGS=()
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    --regen) REGEN=1 ;;
    --check) CHECK=1 ;;
    --*) usage ;;
    *) ARGS+=("$a") ;;
  esac
done
[ "${#ARGS[@]}" -eq 2 ] || usage
MODULE="${ARGS[0]}"
NAME="${ARGS[1]}"

MODULE_RE='^[a-z0-9][a-z0-9._-]*(/[A-Za-z0-9._-]+)*$'
NAME_RE='^[a-z][a-z0-9]*$'
# Reserved words: names the context rules would corrupt, because the repository uses them as a
# path component (web/api/internal/..., deploy/, scripts/, data/, logs/, releases/, current/),
# as a target after a $VAR/ or ~/ prefix (the rules turn "$root/web" into "$root/<name>"), or as a
# common variable or fixture word in the scripts. Derived from `git ls-files` path components and
# the `$VAR/<word>` / prefix uses in web/scripts/, web/test/, web/deploy/ and web/Makefile. It also holds the
# names of the TOOLS the scripts, the Makefile and CI invoke (`command -v go`, `web/api/go.mod`,
# `git describe`, `pnpm`) and the fixture words of the shell tests (`$T/notify`, `$T/style`): a
# project with such a name would have those occurrences rewritten. rename.test.sh
# fails when a tracked directory name is missing here; add new directories and variable targets.
RESERVED="web api apigen apptest internal cmd tests test testing testutil data db logs log storage static pages public docs deploy scripts script ios android src node bin tmp lib backup backups releases current dist config client commands hooks workflows e2e fixtures embed migrations models handlers auth notes server version uid layout logging main middleware package schema settings setup smoke restore rename home base body build calls case claude curl custom dest dirty empty err fake gen head healthz index install junk master mirror new out owner pid post pull remote renamed roundtrip rsync set site slow ssh started stderr systemctl tracked pre page marker systemd nginx x to go git pnpm sh node make bash curl ssh rsync systemctl launchctl loginctl sqlite3 openssl python3 jq perl awk sed tar ss timeout gtimeout osascript plutil sha256sum shasum wget corepack npm npx tsc agents c dcalls does err1 fakebin fakecurl h lbin lc nogit noop notified notify out1 proj rbin recorded ren res style t repo dirname"
reserved_word() { case " $RESERVED " in *" $1 "*) return 0 ;; esac; return 1; }
[[ "$MODULE" =~ $MODULE_RE ]] || die "invalid module path '$MODULE': use lowercase letters, digits, '.', '_' and '-', with '/' separated segments (for example github.com/acme/shop)"
[[ "$NAME" =~ $NAME_RE ]] || die "invalid name '$NAME': use a lowercase letter followed by lowercase letters and digits only (for example shop)"

! reserved_word "$NAME" || die "the name '$NAME' is reserved: it is a directory or variable word of this repository and renaming to it would corrupt files. Pick another name (the list is RESERVED in web/scripts/rename.sh)"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$here/../.." && pwd)"
cd "$ROOT"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git work tree: run this in a clone of the starter"
[ "$(git rev-parse --show-toplevel)" = "$(pwd -P)" ] || die "this script must live in the root of its own git work tree"

# Current names, read from the repository.
OLD_MODULE="$(sed -n 's/^module[[:space:]][[:space:]]*\([^[:space:]]*\)[[:space:]]*$/\1/p' web/api/go.mod 2>/dev/null | head -1)"
[ -n "$OLD_MODULE" ] || die "cannot read the module path from web/api/go.mod"
cmds=(); for d in web/api/cmd/*/; do [ -d "$d" ] && cmds+=("$(basename "$d")"); done
[ "${#cmds[@]}" -eq 1 ] || die "expected exactly one directory under web/api/cmd/, found ${#cmds[@]}"
OLD="${cmds[0]}"
! reserved_word "$OLD" || die "the current name '$OLD' is reserved (a directory or variable word of this repository): web/scripts/rename.sh cannot rename away from it safely; rename by hand or restore a non-reserved name"
[[ "$OLD" =~ $NAME_RE ]] || die "the current command directory name '$OLD' is not a plain lowercase name"

if [ "$MODULE" = "$OLD_MODULE" ] && [ "$NAME" = "$OLD" ]; then
  echo "rename: module path and name are already '$OLD_MODULE' and '$OLD'; nothing to do."
  exit 0
fi

if [ "$FORCE" -ne 1 ] && [ "$CHECK" -ne 1 ] && [ -n "$(git status --porcelain)" ]; then
  die "uncommitted changes found: commit or stash them first (or pass --force)"
fi

NAME_UPPER="$(printf '%s' "$NAME" | tr '[:lower:]' '[:upper:]')"
OLD_UPPER="$(printf '%s' "$OLD" | tr '[:lower:]' '[:upper:]')"
TOKEN="@@RENAME_MODULE_PATH@@"

excluded() {
  case "$1" in
    docs/superpowers/*|.claude/skills/*|*/node_modules/*|web/pnpm-lock.yaml|pnpm-lock.yaml|.git/*) return 0 ;;
    web/scripts/rename.sh|web/scripts/rename.test.sh) return 0 ;;   # these read the names from the repo
  esac
  return 1
}

# The context rules, in perl. A = a character that continues a word.
read -r -d '' RULES <<'PERL' || true
BEGIN {
  $m = $ENV{OLD_MODULE}; $o = $ENV{OLD_NAME}; $n = $ENV{NEW_NAME};
  $ou = $ENV{OLD_UPPER}; $nu = $ENV{NEW_UPPER}; $t = $ENV{TOK}; $f = $ENV{FILE};
  $A = '[A-Za-z0-9_]';
  $pre = 'cmd/|dist/|current/|uploading/|Backups/|backups/|\.config/|Logs/|~/|\$HOME/|%h/|/opt/|/home/deploy/|/home/|/h/|\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/|releases/[^/\s]+/';
}
# 1. module path (parked behind a token so it survives the later steps)
s{^module \Q$m\E[ \t]*$}{module $t}m;
s{(?<![\w./~-])\Q$m\E/(internal|cmd|tests)(?!$A)}{$t/$1}g;
s{\Q$m\E}{$t}g if index($m, "/") >= 0;
# 2. upper-case env vars of the project (APP_ENV is shared and stays)
s{(?<![A-Za-z0-9])\Q$ou\E_(BIN|AUTH_PANIC_CHILD)(?!$A)}{${nu}_$1}g;
# 3. before an identifier suffix
s{(?<!$A)\Q$o\E(?=(?:\.db|\.service|-backup|-pull|-e2e|-web|-development-only|_session))}{$n}g;
# 4. after a path prefix
s{((?:$pre))\Q$o\E(?!$A|\.go\b|/internal|\.tsx?\b|\.mjs)}{$1$n}g;
s{web/api/\Q$o\E(?![A-Za-z0-9_/])}{web/api/$n}g;
s{(?<!$A)\Q$o\E(?=/(?:current|data|releases|\.env|\.deploy|restore\.sh|pull-gate))}{$n}g;
s{home_\Q$o\E_current}{home_${n}_current}g;
# launchd: the label com.<name>.backup-pull, and the process name shown by `ss -p`
s{(?<![A-Za-z0-9_])(com\.)\Q$o\E(\.)}{$1$n$2}g;
s{(users:\(\(")\Q$o\E(")}{$1$n$2}g;
# 5. defaults and variables
s{((?:SERVICE|REMOTE_BASE|APP_NAME|FAKE_EXPECT_UNIT)(?::-|=))\Q$o\E(?!$A)}{$1$n}g;
s{(?<![A-Za-z0-9_.])(default `?)\Q$o\E(?!$A)(?=`?[):.,\s]|`?$)}{$1$n}g;
# 6. the command
s{(else `)\Q$o\E(` on PATH)}{$1$n$2}g;
s{(path\.join\(\w+, ")\Q$o\E(")}{$1$n$2}g;
s{(command -v )\Q$o\E(?!$A)}{$1$n}g;
s{"\Q$o\E(: unknown command")}{"$n$1}g;
s{(building )\Q$o\E(?= (?:\$VERSION|\.\.\.))}{$1$n}g;
s{(<h1>)\Q$o\E(</h1>)}{$1$n$2}g;
s{^(\s*title: )\Q$o\E( API)$}{$1$n$2}mg;
s{(?<!$A)\Q$o\E(?= (?:backup|serve|user create|verify-backup|schema-version)(?!$A))}{$n}g;
s{(usage: )\Q$o\E(?= )}{$1$n}g;
s{^// Command \Q$o\E }{// Command $n }m;
s{"\Q$o\E:}{"$n:}g if $f =~ m{^web/api/cmd/};
# 7. systemd and nginx
s{^(Description=|User=|Group=)\Q$o\E(?!$A)}{$1$n}mg;
s{(?<!$A)(upstream |proxy_pass http://|-u |enable --now |enable |status |restart |start |stop |show |reset-failed )\Q$o\E(?![A-Za-z0-9_.-])}{$1$n}g;
s{(Description=)\Q$o\E }{$1$n }g;
s{(Run the )\Q$o\E( backup daily)}{$1$n$2}g;
s{(systemd USER unit for )\Q$o\E(?!$A)}{$1$n}g;
# 8. HTML pages: title, brand link, h1 and the "What is" heading
if ($f =~ m{\.html$} && m{<title>|<h1|class="brand"|<h2>What is }) {
  s{(?<![A-Za-z0-9_./-])\Q$o\E(?![A-Za-z0-9_-])}{$n}g;
}
# 9. restore the module path
s{\Q$t\E}{$ENV{NEW_MODULE}}g;
PERL

# Run-time round-trip check. Renaming to <name> is only reversible when <name> does not already
# occur in the tree in a context the rules rewrite: the reverse rename (<name> -> anything) would
# then rewrite that pre-existing occurrence too. So treat the NEW name as the current one and run
# the rules over the current tree with a probe replacement; if any file would change, refuse.
# RESERVED above is only a fast pre-filter for this. The module path and the name are probed separately,
# and only the part that actually changes (an unchanged part would match the whole tree).
# probe_pass <module-as-current> <name-as-current> <upper>: print the first tracked file the rules would
# change when those are treated as the current names (replacement: a probe). Unchanged parts of the
# rename are probed with sentinels that occur nowhere, so only the part that really changes is tested.
probe_pass() {
  local f
  while IFS= read -r -d '' f; do
    excluded "$f" && continue
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    grep -Iq . "$f" 2>/dev/null || continue
    if ! OLD_MODULE="$1" NEW_MODULE="rename-probe.invalid/probe" OLD_NAME="$2" NEW_NAME="zzprobe" \
         OLD_UPPER="$3" NEW_UPPER="ZZPROBE" TOK="$TOKEN" FILE="$f" \
         perl -p -e "$RULES" "$f" | cmp -s - "$f"; then
      echo "$f"; return 0
    fi
  done < <(git ls-files -z)
  return 0
}
SENT_MODULE="rename-probe.invalid/unchanged"; SENT_NAME="zzunchanged"
if [ "$MODULE" != "$OLD_MODULE" ]; then
  hit="$(probe_pass "$MODULE" "$SENT_NAME" ZZUNCHANGED)"
  [ -z "$hit" ] || die "the module path '$MODULE' already occurs in the repository (first in $hit), so renaming to it could not be undone exactly. Pick another module path."
fi
if [ "$NAME" != "$OLD" ]; then
  hit="$(probe_pass "$SENT_MODULE" "$NAME" "$NAME_UPPER")"
  [ -z "$hit" ] || die "the name '$NAME' already occurs in the repository in a context this script rewrites (first in $hit), so renaming to it could not be undone exactly. Pick another name."
fi

if [ "$CHECK" -eq 1 ]; then
  echo "rename: --check: module '$MODULE' and name '$NAME' would be accepted; nothing was changed."
  exit 0
fi

CHANGED=0
while IFS= read -r -d '' f; do
  excluded "$f" && continue
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  grep -Iq . "$f" 2>/dev/null || continue            # binary or empty
  grep -q -i -e "$OLD" -e "$OLD_MODULE" "$f" 2>/dev/null || continue
  before="$(cksum < "$f")"
  OLD_MODULE="$OLD_MODULE" NEW_MODULE="$MODULE" OLD_NAME="$OLD" NEW_NAME="$NAME" \
    OLD_UPPER="$OLD_UPPER" NEW_UPPER="$NAME_UPPER" TOK="$TOKEN" FILE="$f" \
    perl -pi -e "$RULES" "$f"
  [ "$(cksum < "$f")" = "$before" ] || CHANGED=$((CHANGED+1))
done < <(git ls-files -z)

# Move only the paths that carry the project name: the command directory and the unit files.
MOVED=0
while IFS= read -r -d '' f; do
  case "$f" in
    "web/api/cmd/$OLD/"*) new="web/api/cmd/$NAME/${f#web/api/cmd/$OLD/}" ;;
    "web/deploy/$OLD.service"|"web/deploy/$OLD-backup.service"|"web/deploy/$OLD-backup.timer") new="web/deploy/$NAME${f#web/deploy/$OLD}" ;;
    *) continue ;;
  esac
  [ "$new" = "$f" ] && continue   # only the module path changed: nothing to move
  mkdir -p "$(dirname "$new")"
  git mv "$f" "$new"
  rmdir "$(dirname "$f")" 2>/dev/null || true   # drop the emptied old directory
  MOVED=$((MOVED+1))
done < <(git ls-files -z)

if [ "$REGEN" -eq 1 ]; then
  bash web/scripts/gen-api.sh
fi

echo "rename: module '$MODULE', name '$NAME': $CHANGED files rewritten, $MOVED files moved."
cat <<NEXT

The name was replaced only where it is an identifier, a path, a unit, a cookie, a database or a
page title. Prose that merely mentions it was left alone: read these by hand.

Next steps:
  - update the README title and text, and the public page copy (web/public/pages/)
  - add a LICENSE of your choice
  - on the server, create .env from web/deploy/.env.example and set SESSION_SECRET and PUBLIC_ORIGIN
  - point the git remote at your repository: git remote set-url origin <url>
  - run: make -C web test
NEXT
