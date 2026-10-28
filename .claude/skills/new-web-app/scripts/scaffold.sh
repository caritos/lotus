#!/usr/bin/env bash
# Turn ~/src/goweb (its committed HEAD) into a new app and apply Eladio's hosting specifics.
# Usage: scaffold.sh <repo-dir> <slug> "<Display Name>" "<one-line description>" [--port N] [--allow-dirty]
# Exit: 0 done; 1 refusal (goweb missing or dirty, file collision, fast tier failed); 2 bad input.
# goweb is read-only here: GOWEB_DIR (default ~/src/goweb), `git archive HEAD` only.
# Everything is built in a temp git repo first and copied into <repo-dir> only at the end, so a
# failure at any point leaves <repo-dir> untouched. The script does not commit.
set -euo pipefail

usage() { echo 'usage: scaffold.sh <repo-dir> <slug> "<Display Name>" "<description>" [--port N] [--allow-dirty]' >&2; exit 2; }
bad() { echo "scaffold: $*" >&2; exit 2; }
refuse() { echo "scaffold: $*" >&2; exit 1; }

POS=(); PORT=""; HAVE_PORT=0; ALLOW_DIRTY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --allow-dirty) ALLOW_DIRTY=1 ;;
    --port) [ $# -ge 2 ] || bad "--port needs a value"; PORT="$2"; HAVE_PORT=1; shift ;;
    --*) usage ;;
    *) POS+=("$1") ;;
  esac
  shift
done
[ "${#POS[@]}" -eq 4 ] || usage
TARGET_ARG="${POS[0]}"; SLUG="${POS[1]}"; NAME="${POS[2]}"; DESC="${POS[3]}"

[[ "$SLUG" =~ ^[a-z][a-z0-9]*$ ]] || bad "invalid slug '$SLUG': a lowercase letter, then lowercase letters and digits"
for v in "$NAME" "$DESC"; do
  case "$v" in
    ""|*"|"*|*"%"*|*"\\"*|*'"'*|*$'\n'*|*$'\r'*)
      bad "name and description must be non-empty and must not contain | % \\ \" or a newline" ;;
  esac
done
if [ "$HAVE_PORT" -eq 1 ]; then
  [[ "$PORT" =~ ^[0-9]+$ ]] && [ "${#PORT}" -le 5 ] && [ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] \
    || bad "invalid --port '$PORT': use 1024-65535 (pick a free one with ss -tln on the server)"
  ADDR_PORT="$PORT"
else
  ADDR_PORT="SET_PORT_FIRST"   # not numeric on purpose: scripts/deploy-app.sh refuses it
fi

# Resolve the target now: later steps cd into the temp stage, which would swallow a relative path.
case "$TARGET_ARG" in /*) TARGET_ABS="$TARGET_ARG" ;; *) TARGET_ABS="$PWD/$TARGET_ARG" ;; esac

GOWEB="${GOWEB_DIR:-$HOME/src/goweb}"
git -C "$GOWEB" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || refuse "goweb not found at $GOWEB (set GOWEB_DIR); it must be a git repository"
if [ "$ALLOW_DIRTY" -ne 1 ] && [ -n "$(git -C "$GOWEB" status --porcelain)" ]; then
  refuse "goweb has uncommitted changes and only its committed HEAD is used; commit them or pass --allow-dirty"
fi
ORIGIN="$(git -C "$GOWEB" rev-parse HEAD)"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/new-web-app.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
W="$STAGE/work"; X="$STAGE/export"; LOG="$STAGE/build.log"
mkdir "$W" "$X"
gitc() { git -C "$W" -c user.name=scaffold -c user.email=scaffold@localhost -c commit.gpgsign=false "$@"; }
fail_stage() { echo "scaffold: $1 failed; $TARGET_ARG was not touched. Last output:" >&2; tail -n 25 "$LOG" >&2; exit 1; }

# html_escape: stdin to stdout, & first.
html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e "s/'/\&#39;/g"; }
NAME_H="$(printf '%s' "$NAME" | html_escape)"
DESC_H="$(printf '%s' "$DESC" | html_escape)"
# sq: shell-quote a value in single quotes.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# replace_in <perl-substitution-using-$ENV> <file...>: values travel through the environment,
# so nothing in the name or description is ever re-parsed as a pattern or a shell word.
replace_in() { local expr="$1"; shift; perl -0pi -e "$expr" "$@"; }
# set_line <file> <regex> <line>: replace the first matching line, or append the line.
set_line() {
  if grep -Eq "$2" "$1"; then SL_RE="$2" SL_LINE="$3" perl -pi -e 'BEGIN{$d=0} if(!$d && /$ENV{SL_RE}/){ $_="$ENV{SL_LINE}\n"; $d=1 }' "$1"
  else printf '%s\n' "$3" >> "$1"; fi
}

# ---- 1. stage goweb's HEAD in a temp git repo (rename.sh needs tracked files and a clean tree)
git -C "$GOWEB" archive HEAD | tar -x -C "$W"
gitc init -q; gitc add -A; gitc commit -q -m "goweb $ORIGIN"
cd "$W"

# ---- 2. mark the display-name spots with tokens (rename.sh would turn them into the slug)
PAGE_FILES=(web/api/internal/web/pages/*.html)
[ -e "${PAGE_FILES[0]}" ] || refuse "goweb has no web/api/internal/web/pages/*.html"
replace_in 's/goweb is a placeholder name\. Replace this footer with your own\./\@\@WRAP_NAME\@\@ - contact support\@caritos.com/g;
            s/simple notes with photos/\@\@WRAP_DESC\@\@/g;
            s/[ \t]*<p class="note">Replace support\@example\.com[^\n]*\n//g;
            s/support\@example\.com/support\@caritos.com/g;
            s/goweb/\@\@WRAP_NAME\@\@/g' "${PAGE_FILES[@]}"
[ ! -f web/index.html ] || replace_in 's/goweb/\@\@WRAP_NAME\@\@/g' web/index.html
[ ! -f README.md ] || replace_in 's/\A# goweb\n/# \@\@WRAP_NAME\@\@\n\n\@\@WRAP_DESC\@\@\n/' README.md
gitc add -A; gitc commit -q -m "mark display name"

# ---- 3. rename the module, binary, units and paths
bash scripts/rename.sh "github.com/caritos/$SLUG" "$SLUG" >"$LOG" 2>&1 || fail_stage "scripts/rename.sh"
gitc add -A; gitc commit -q -m rename

# ---- 4. display name and description, HTML-escaped
SUBST_FILES=("${PAGE_FILES[@]}")
[ ! -f web/index.html ] || SUBST_FILES+=(web/index.html)
[ ! -f README.md ] || SUBST_FILES+=(README.md)
NAME_H="$NAME_H" DESC_H="$DESC_H" replace_in 's/\@\@WRAP_NAME\@\@/$ENV{NAME_H}/g; s/\@\@WRAP_DESC\@\@/$ENV{DESC_H}/g' "${SUBST_FILES[@]}"

# ---- 5. Eladio's hosting defaults
set_line .env.example '^ADDR=' "ADDR=0.0.0.0:$ADDR_PORT"
set_line .env.example '^PUBLIC_ORIGIN=' "PUBLIC_ORIGIN=https://$SLUG.caritos.com"
BP=scripts/backup-pull.env.example
set_line "$BP" '^#?REMOTE_DIR=' "REMOTE_DIR=$SLUG/data/backups"
set_line "$BP" '^#?DEST=' "DEST=\$HOME/Backups/$SLUG"
set_line "$BP" '^#?MIRROR_DIR=' "MIRROR_DIR=\"/Volumes/Treasure Chest/backups/$SLUG\""

cat > scripts/deploy-app.sh <<'EOS'
#!/usr/bin/env bash
# Mac-side deploy settings for __SLUG__, then scripts/deploy.sh: ./scripts/deploy-app.sh <user@host> [--check]
# Generated by the new-web-app skill; scripts/deploy.sh itself stays generic.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADDR_LINE="$(grep '^ADDR=' "$HERE/../.env.example" || true)"
PORT="${ADDR_LINE##*:}"
case "$PORT" in
  ""|*[!0-9]*)
    echo "deploy-app: the app's port is not set. Pick a free port on the server (ss -tln, then ps aux), then set ADDR=0.0.0.0:<port> in .env.example and in the server .env, and the same port in the DreamHost panel Proxy Server. Nothing was changed." >&2
    exit 1 ;;
esac
export PUBLIC_URL=https://__SLUG__.caritos.com
export EXPECT_PUBLIC_LISTENER=1
# deploy.sh refuses to deploy unless ${SERVICE}-backup.timer is enabled on the server
export REQUIRE_BACKUP_TIMER=1
# smoke.sh looks for this text in the home page HTML, so it is the HTML-escaped display name
export APP_NAME=__NAME_Q__
exec bash "$HERE/deploy.sh" "$@"
EOS
SLUG="$SLUG" NAME_Q="$(sq "$NAME_H")" replace_in 's/__SLUG__/$ENV{SLUG}/g; s/__NAME_Q__/$ENV{NAME_Q}/g' scripts/deploy-app.sh
chmod +x scripts/deploy-app.sh
printf '%s\n' "$ORIGIN" > .goweb-origin

# ---- 6. fast tier in the staged copy (a failure means nothing is copied)
gitc add -A; gitc commit -q -m "app settings"
if [ -f web/package.json ] && command -v pnpm >/dev/null 2>&1; then
  (cd web && pnpm install --frozen-lockfile) >"$LOG" 2>&1 || fail_stage "pnpm install"
fi
make test-fast >"$LOG" 2>&1 || fail_stage "make test-fast"

# ---- 7. plan the copy; refuse on any collision before writing anything
gitc archive HEAD | tar -x -C "$X"
mkdir -p "$TARGET_ABS"
[ -d "$TARGET_ABS" ] || refuse "$TARGET_ARG is not a directory"
T="$(cd "$TARGET_ABS" && pwd -P)"
COPY=(); DEST_OF=(); NOTES=(); COLLIDE=(); POINTER=0; GITIGNORE=0; L3_HOST=()
[ ! -d "$T/ios" ] || L3_HOST+=("ios/")
[ ! -e "$T/CLAUDE.md" ] || L3_HOST+=("a root CLAUDE.md")
while IFS= read -r -d '' rel; do
  rel="${rel#./}"; dest="$rel"
  case "$rel" in
    .gitignore) GITIGNORE=1; [ -e "$T/.gitignore" ] && continue ;;
    CLAUDE.md) if [ -e "$T/CLAUDE.md" ]; then dest="web/CLAUDE.md"; POINTER=1; fi ;;
    README.md|AGENTS.md) if [ -e "$T/$rel" ]; then NOTES+=("skipped $rel (already exists in $TARGET_ARG)"); continue; fi ;;
    ios/*) if [ -d "$T/ios" ]; then
             case "${NOTES[*]:-}" in *"skipped ios/"*) ;; *) NOTES+=("skipped ios/ (the target already has ios/; goweb's placeholder was not copied)") ;; esac
             continue
           fi ;;
  esac
  if [ -e "$T/$dest" ] || [ -L "$T/$dest" ]; then COLLIDE+=("$dest"); continue; fi
  COPY+=("$rel"); DEST_OF+=("$dest")
done < <(cd "$X" && find . \( -type f -o -type l \) -print0)
if [ "${#COLLIDE[@]}" -gt 0 ]; then
  echo "scaffold: these files already exist in $TARGET_ARG; nothing was changed:" >&2
  printf '  %s\n' "${COLLIDE[@]}" >&2
  exit 1
fi

# ---- 8. copy
i=0
while [ "$i" -lt "${#COPY[@]}" ]; do
  mkdir -p "$(dirname "$T/${DEST_OF[$i]}")"
  cp -p "$X/${COPY[$i]}" "$T/${DEST_OF[$i]}"
  i=$((i+1))
done
if [ "$GITIGNORE" -eq 1 ] && [ -e "$T/.gitignore" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    grep -qxF -- "$line" "$T/.gitignore" && continue
    [ -z "$(tail -c1 "$T/.gitignore")" ] || printf '\n' >> "$T/.gitignore"
    printf '%s\n' "$line" >> "$T/.gitignore"
  done < "$X/.gitignore"
fi
if [ "$POINTER" -eq 1 ]; then
  PTR="Web app (Go + React): see web/CLAUDE.md."
  grep -qxF -- "$PTR" "$T/CLAUDE.md" || {
    [ -z "$(tail -c1 "$T/CLAUDE.md")" ] || printf '\n' >> "$T/CLAUDE.md"
    printf '%s\n' "$PTR" >> "$T/CLAUDE.md"
  }
fi

echo "scaffold: $NAME ($SLUG) written to $T from goweb ${ORIGIN:0:7}; goweb's fast tier passed in the copy."
[ "${#NOTES[@]}" -eq 0 ] || printf 'scaffold: %s\n' "${NOTES[@]}"
if [ "${#L3_HOST[@]}" -gt 0 ]; then
  echo "scaffold: WARNING (goweb L3): $TARGET_ARG already had ${L3_HOST[*]}. \`make test\` in this app will fail at scripts/layout.test.sh until goweb's guard is made host-aware (goweb L3, see the config repo CLAUDE.md). \`make test-fast\` and the other tiers are unaffected."
fi
cat <<EOS

REWRITE THE PUBLIC COPY: web/api/internal/web/pages/ (privacy, terms, FAQ, support, home) still describes goweb's
example notes app. Rewrite all of it for the real app before release; only the name and footer were changed.

One-time setup (details in the skill):
  1. DreamHost panel: add $SLUG.caritos.com (domain), then VPS Management -> Proxy Server -> the app's port.
  2. ssh-copy-id -i ~/.ssh/id_ed25519.pub <user>@<host>   (a FULL shell user, not SFTP-only)
  3. Free port: ss -tln, then ps aux for who owns a taken one.$( [ "$HAVE_PORT" -eq 1 ] || echo " Re-run with --port N or edit ADDR in .env.example." )
  4. Server .env from .env.example (docs/deploy.md); then: scripts/deploy-app.sh <user>@<host> --check
  5. Mac backups: copy scripts/backup-pull.env.example to ~/.config/$SLUG/backup-pull.env, set REMOTE, run scripts/install-backup-agent.sh
EOS
