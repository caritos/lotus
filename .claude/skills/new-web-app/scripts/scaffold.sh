#!/usr/bin/env bash
# Turn the starter repo this skill lives in (its committed HEAD) into a new app and apply Eladio's hosting specifics.
# Usage: scaffold.sh <repo-dir> <slug> "<Display Name>" "<one-line description>" [--port N] [--allow-dirty]
# Exit: 0 done; 1 refusal (starter missing or dirty, file collision, fast tier failed); 2 bad input (incl. a slug the starter's rename.sh refuses).
# The starter is read-only here: LOTUS_DIR (default: the repo this script lives in), `git archive HEAD` only.
# The skills under .claude/skills/ never go into the new app.
# Neither does the starter's rename self-test (web/scripts/rename.test.sh), which cannot pass in a renamed app.
# Everything is built in a temp git repo first and copied into <repo-dir> only at the end, so a
# failure at any point leaves <repo-dir> untouched. The script does not commit.
set -euo pipefail

# ---- every path to a starter file lives here (the starter's layout may move; change only this block)
SCRIPTS_DIR="web/scripts"                          # every script of the starter (web/ holds the whole web platform)
RENAME_SH="$SCRIPTS_DIR/rename.sh"
DEPLOY_SH="deploy.sh"                              # inside SCRIPTS_DIR; deploy-app.sh execs it
DEPLOY_APP_SH="$SCRIPTS_DIR/deploy-app.sh"         # generated
BACKUP_ENV_EXAMPLE="$SCRIPTS_DIR/backup-pull.env.example"
ENV_EXAMPLE="web/deploy/.env.example"
PAGES_GLOB="web/public/pages/*.html"
WEB_INDEX="web/index.html"
README_FILE="README.md"
ROOT_CLAUDE_MD="CLAUDE.md"; WEB_CLAUDE_MD="web/CLAUDE.md"   # where the starter's CLAUDE.md goes when the host has one
SKILLS_DIR=".claude/skills"                        # excluded from what a new app copies
# The wrapper marker is a fixed contract with the starter's layout guard (web/scripts/layout.test.sh builds
# the same name from two pieces so rename.sh cannot rewrite it).
ORIGIN_FILE=".lo""tus-origin"
# Text in the starter that the wrapper replaces (the starter's shipped name is the bare word `app`).
STARTER_FOOTER='The name in the header is a placeholder. Replace this footer with your own.'
STARTER_TAGLINE='simple notes with photos'

SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do   # follow symlinks (the skill is linked into ~/.claude/skills)
  d="$(cd "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF" ;; esac
done
SELF_DIR="$(cd "$(dirname "$SELF")" && pwd -P)"
# .claude/skills/new-web-app/scripts -> the repo root is 4 levels up
DEFAULT_STARTER="$(cd "$SELF_DIR/../../../.." && pwd -P)"

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
  ADDR_PORT="SET_PORT_FIRST"   # not numeric on purpose: web/scripts/deploy-app.sh refuses it
fi

# Resolve the target now: later steps cd into the temp stage, which would swallow a relative path.
case "$TARGET_ARG" in /*) TARGET_ABS="$TARGET_ARG" ;; *) TARGET_ABS="$PWD/$TARGET_ARG" ;; esac

LOTUS="${LOTUS_DIR:-$DEFAULT_STARTER}"
git -C "$LOTUS" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || refuse "the starter was not found at $LOTUS (set LOTUS_DIR); it must be a git repository"
if [ "$ALLOW_DIRTY" -ne 1 ] && [ -n "$(git -C "$LOTUS" status --porcelain)" ]; then
  refuse "the starter at $LOTUS has uncommitted changes and only its committed HEAD is used; commit them or pass --allow-dirty"
fi
ORIGIN="$(git -C "$LOTUS" rev-parse HEAD)"

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

# ---- 1. stage the starter's HEAD in a temp git repo (rename.sh needs tracked files and a clean tree)
git -C "$LOTUS" archive HEAD | tar -x -C "$W"
rm -rf "${W:?}/$SKILLS_DIR"     # the skills stay in the starter; a new app does not carry them
# the starter's own logo and the README line that shows it stay in the starter too
LOGO="docs/logo.jpg"
if [ -f "$W/$LOGO" ]; then
  rm -f "${W:?}/$LOGO"
  [ ! -f "$W/$README_FILE" ] || { grep -v "$LOGO" "$W/$README_FILE" > "$W/$README_FILE.tmp" || true; mv "$W/$README_FILE.tmp" "$W/$README_FILE"; }
fi
# the starter's rename self-test checks rename.sh against the starter itself and cannot pass in a renamed app
RENAME_TEST="$SCRIPTS_DIR/rename.test.sh"
if [ -f "$W/$RENAME_TEST" ]; then
  rm -f "${W:?}/$RENAME_TEST"
  for f in web/Makefile "$SCRIPTS_DIR/layout.test.sh"; do
    [ ! -f "$W/$f" ] || { sed -e '/scripts\/rename\.test\.sh/d' -e 's/ rename\.test\.sh / /' "$W/$f" > "$W/$f.tmp"; cat "$W/$f.tmp" > "$W/$f"; rm -f "$W/$f.tmp"; }
  done
fi
gitc init -q; gitc add -A; gitc commit -q --allow-empty -m "starter $ORIGIN"
cd "$W"

# ---- 1b. the starter's own rename.sh validates the slug (reserved words and names it could not undo)
[ -f "$RENAME_SH" ] || refuse "the starter has no $RENAME_SH"
if ! chk="$(bash "$RENAME_SH" --check "github.com/caritos/$SLUG" "$SLUG" 2>&1)"; then
  echo "scaffold: the starter's $RENAME_SH refused the slug '$SLUG'; $TARGET_ARG was not touched:" >&2
  printf '%s\n' "$chk" | sed 's/^/  /' >&2
  exit 2
fi

# ---- 2. mark the display-name spots with tokens. rename.sh rewrites EVERY bare word `app` in an HTML page
# that has a title, brand link or h1 (prose too), and the README title is left alone, so: the display-name
# spots become @@WRAP_NAME@@ and every other bare `app` becomes @@WRAP_APP@@ (restored after the rename).
PAGE_FILES=($PAGES_GLOB)
[ -e "${PAGE_FILES[0]}" ] || refuse "the starter has no $PAGES_GLOB"
WORDRE='(?<![A-Za-z0-9_./-])app(?![A-Za-z0-9_-])'   # the word rule 8 of rename.sh rewrites
FOOTER="$STARTER_FOOTER" TAGLINE="$STARTER_TAGLINE" replace_in 's/\Q$ENV{FOOTER}\E/\@\@WRAP_NAME\@\@ - contact support\@caritos.com/g;
            s/\Q$ENV{TAGLINE}\E/\@\@WRAP_DESC\@\@/g;
            s/[ \t]*<p class="note">Replace support\@example\.com[^\n]*\n//g;
            s/support\@example\.com/support\@caritos.com/g;
            s{(<title>[^<]*?)'"$WORDRE"'}{$1\@\@WRAP_NAME\@\@};
            s{(class="brand"[^>]*>)app(</a>)}{$1\@\@WRAP_NAME\@\@$2};
            s{(<h1>)app(</h1>)}{$1\@\@WRAP_NAME\@\@$2};
            s{(<h2>What is )app(\?</h2>)}{$1\@\@WRAP_NAME\@\@$2}g;
            s{'"$WORDRE"'}{\@\@WRAP_APP\@\@}g' "${PAGE_FILES[@]}"
if [ -f "$WEB_INDEX" ]; then
  replace_in 's{(<title>[^<]*?)'"$WORDRE"'}{$1\@\@WRAP_NAME\@\@};
              s{'"$WORDRE"'}{\@\@WRAP_APP\@\@}g' "$WEB_INDEX"
fi
[ ! -f "$README_FILE" ] || replace_in 's/\A# app\n/# \@\@WRAP_NAME\@\@\n\n\@\@WRAP_DESC\@\@\n/' "$README_FILE"
gitc add -A; gitc commit -q --allow-empty -m "mark display name"

# ---- 3. rename the module, binary, units and paths
bash "$RENAME_SH" "github.com/caritos/$SLUG" "$SLUG" >"$LOG" 2>&1 || fail_stage "$RENAME_SH"
gitc add -A; gitc commit -q --allow-empty -m rename

# ---- 4. display name and description, HTML-escaped
SUBST_FILES=("${PAGE_FILES[@]}")
[ ! -f "$WEB_INDEX" ] || SUBST_FILES+=("$WEB_INDEX")
[ ! -f "$README_FILE" ] || SUBST_FILES+=("$README_FILE")
NAME_H="$NAME_H" DESC_H="$DESC_H" replace_in 's/\@\@WRAP_NAME\@\@/$ENV{NAME_H}/g; s/\@\@WRAP_DESC\@\@/$ENV{DESC_H}/g; s/\@\@WRAP_APP\@\@/app/g' "${SUBST_FILES[@]}"

# ---- 5. Eladio's hosting defaults
set_line "$ENV_EXAMPLE" '^ADDR=' "ADDR=0.0.0.0:$ADDR_PORT"
set_line "$ENV_EXAMPLE" '^PUBLIC_ORIGIN=' "PUBLIC_ORIGIN=https://$SLUG.caritos.com"
BP="$BACKUP_ENV_EXAMPLE"
set_line "$BP" '^#?REMOTE_DIR=' "REMOTE_DIR=$SLUG/data/backups"
set_line "$BP" '^#?DEST=' "DEST=\$HOME/Backups/$SLUG"
set_line "$BP" '^#?MIRROR_DIR=' "MIRROR_DIR=\"/Volumes/Treasure Chest/backups/$SLUG\""

cat > "$DEPLOY_APP_SH" <<'EOS'
#!/usr/bin/env bash
# Mac-side deploy settings for __SLUG__, then web/scripts/deploy.sh: web/scripts/deploy-app.sh <user@host> [--check]
# Generated by the new-web-app skill; web/scripts/deploy.sh itself stays generic.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADDR_LINE="$(grep '^ADDR=' "$HERE/__ENV_REL__" || true)"
PORT="${ADDR_LINE##*:}"
case "$PORT" in
  ""|*[!0-9]*)
    echo "deploy-app: the app's port is not set. Pick a free port on the server (ss -tln, then ps aux), then set ADDR=0.0.0.0:<port> in __ENV_NAME__ and in the server .env, and the same port in the DreamHost panel Proxy Server. Nothing was changed." >&2
    exit 1 ;;
esac
export PUBLIC_URL=https://__SLUG__.caritos.com
export EXPECT_PUBLIC_LISTENER=1
# deploy.sh refuses to deploy unless ${SERVICE}-backup.timer is enabled on the server
export REQUIRE_BACKUP_TIMER=1
# smoke.sh looks for this text in the home page HTML, so it is the HTML-escaped display name
export APP_NAME=__NAME_Q__
exec bash "$HERE/__DEPLOY_SH__" "$@"
EOS
# the generated script sits in the starter's scripts directory, next to deploy.sh; .env.example is found relative to it
ENV_REL="$(perl -e 'use File::Spec; print File::Spec->abs2rel($ARGV[1], $ARGV[0])' "$(dirname "$DEPLOY_APP_SH")" "$ENV_EXAMPLE")"
SLUG="$SLUG" NAME_Q="$(sq "$NAME_H")" ENV_REL="$ENV_REL" ENV_NAME="$ENV_EXAMPLE" DEPLOY_SH="$DEPLOY_SH" \
  replace_in 's/__SLUG__/$ENV{SLUG}/g; s/__NAME_Q__/$ENV{NAME_Q}/g; s/__ENV_REL__/$ENV{ENV_REL}/g; s/__ENV_NAME__/$ENV{ENV_NAME}/g; s/__DEPLOY_SH__/$ENV{DEPLOY_SH}/g' "$DEPLOY_APP_SH"
chmod +x "$DEPLOY_APP_SH"
printf '%s\n' "$ORIGIN" > "$ORIGIN_FILE"

# ---- 6. fast tier in the staged copy (a failure means nothing is copied)
gitc add -A; gitc commit -q --allow-empty -m "app settings"
if [ -f web/package.json ] && command -v pnpm >/dev/null 2>&1; then
  (cd web && pnpm install --frozen-lockfile) >"$LOG" 2>&1 || fail_stage "pnpm install"
fi
make -C web test-fast >"$LOG" 2>&1 || fail_stage "make -C web test-fast"

# ---- 7. plan the copy; refuse on any collision before writing anything
gitc archive HEAD | tar -x -C "$X"
mkdir -p "$TARGET_ABS"
[ -d "$TARGET_ABS" ] || refuse "$TARGET_ARG is not a directory"
T="$(cd "$TARGET_ABS" && pwd -P)"
COPY=(); DEST_OF=(); NOTES=(); COLLIDE=(); POINTER=0; GITIGNORE=0
while IFS= read -r -d '' rel; do
  rel="${rel#./}"; dest="$rel"
  case "$rel" in
    .gitignore) GITIGNORE=1; [ -e "$T/.gitignore" ] && continue ;;
    "$ROOT_CLAUDE_MD") if [ -e "$T/$ROOT_CLAUDE_MD" ]; then dest="$WEB_CLAUDE_MD"; POINTER=1; fi ;;
    "$README_FILE"|AGENTS.md) if [ -e "$T/$rel" ]; then NOTES+=("skipped $rel (already exists in $TARGET_ARG)"); continue; fi ;;
    ios/*) if [ -d "$T/ios" ]; then
             case "${NOTES[*]:-}" in *"skipped ios/"*) ;; *) NOTES+=("skipped ios/ (the target already has ios/; the starter's placeholder was not copied)") ;; esac
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
  PTR="Web app (Go + React): see $WEB_CLAUDE_MD."
  grep -qxF -- "$PTR" "$T/$ROOT_CLAUDE_MD" || {
    [ -z "$(tail -c1 "$T/$ROOT_CLAUDE_MD")" ] || printf '\n' >> "$T/$ROOT_CLAUDE_MD"
    printf '%s\n' "$PTR" >> "$T/$ROOT_CLAUDE_MD"
  }
fi

echo "scaffold: $NAME ($SLUG) written to $T from the starter ${ORIGIN:0:7}; the starter's fast tier passed in the copy."
[ "${#NOTES[@]}" -eq 0 ] || printf 'scaffold: %s\n' "${NOTES[@]}"
cat <<EOS

REWRITE THE PUBLIC COPY: $PAGES_GLOB (privacy, terms, FAQ, support, home) still describes the starter's
example notes app. Rewrite all of it for the real app before release; only the name and footer were changed.

One-time setup (details in the skill):
  1. DreamHost panel: add $SLUG.caritos.com (domain), then VPS Management -> Proxy Server -> the app's port.
  2. ssh-copy-id -i ~/.ssh/id_ed25519.pub <user>@<host>   (a FULL shell user, not SFTP-only)
  3. Free port: ss -tln, then ps aux for who owns a taken one.$( [ "$HAVE_PORT" -eq 1 ] || echo " Re-run with --port N or edit ADDR in $ENV_EXAMPLE." )
  4. Server .env from $ENV_EXAMPLE (web/docs/deploy.md); then: $DEPLOY_APP_SH <user>@<host> --check
  5. Mac backups: copy $BACKUP_ENV_EXAMPLE to ~/.config/$SLUG/backup-pull.env, set REMOTE, run $SCRIPTS_DIR/install-backup-agent.sh
EOS
