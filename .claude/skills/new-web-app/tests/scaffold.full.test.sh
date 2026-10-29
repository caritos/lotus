#!/bin/bash
# Full tier: scaffold from the REAL starter (the repo this skill lives in, or LOTUS_DIR; it must be a clean
# committed tree) into a temp repo that already has ios/ and a root CLAUDE.md, run the starter's own fast tier
# there, run its layout guard (web/scripts/layout.test.sh) in that host-shaped app and in a fresh scaffold, build the
# binary, serve it locally and run the starter's web/scripts/smoke.sh against it with APP_NAME as written by
# web/scripts/deploy-app.sh.
# Needs Node (web/.nvmrc under ~/.nvm, or on PATH), pnpm and Go. lotus's `--check` logs in over ssh and
# cannot run offline; the placeholder-port refusal before any ssh call is tested here and in the fast tier.
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCAFFOLD="$SKILL_DIR/scripts/scaffold.sh"
STARTER_DIR="$(cd "$SKILL_DIR/../../.." && pwd -P)"
MARK=".lo""tus-origin"
F_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nwa-full.XXXXXX")"
SERVER_PID=""
trap '[ -z "$SERVER_PID" ] || { kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; }; rm -rf "$F_ROOT"' EXIT
DISPLAY_NAME="Tom's Notes"

test_scaffold_from_the_real_starter_builds_serves_and_passes_smoke() {
  local lotus="${LOTUS_DIR:-$STARTER_DIR}" r="$F_ROOT/repo" before out port pid
  [ -e "$lotus/.git" ] || { echo "starter not found at $lotus" >&2; return 1; }   # -e: a linked worktree's .git is a file
  before="$(git -C "$lotus" status --porcelain)"
  mkdir -p "$r/ios/App"; echo swift > "$r/ios/App/main.swift"; printf '# Mine\n' > "$r/CLAUDE.md"
  git -C "$r" init -q
  out="$(LOTUS_DIR="$lotus" bash "$SCAFFOLD" "$r" shop "$DISPLAY_NAME" "Notes for Tom" --port 8123 2>&1)" || { echo "$out" >&2; return 1; }
  assert_contains "$out" "skipped ios/"
  assert_eq "swift" "$(cat "$r/ios/App/main.swift")"
  [ ! -e "$r/ios/README.md" ]
  assert_contains "$(cat "$r/CLAUDE.md")" "web/CLAUDE.md"
  [ -f "$r/web/CLAUDE.md" ]
  assert_eq "$before" "$(git -C "$lotus" status --porcelain)" "lotus untouched"

  # leftover starter name anywhere except the origin file and the design history; no skills; no tokens
  local old="lo""tus" left; left="$(grep -rli "$old" "$r" --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=superpowers --exclude="$MARK" || true)"
  [ -z "$left" ] || { echo "$old left in: $left" >&2; return 1; }
  [ ! -e "$r/.claude/skills" ] || { echo ".claude/skills was copied into the app" >&2; return 1; }
  left="$(grep -rl '@@WRAP_' "$r" --exclude-dir=.git --exclude-dir=node_modules || true)"
  [ -z "$left" ] || { echo "unreplaced token in: $left" >&2; return 1; }

  # the replacement patterns must match the real page text, not only the fixture's: the display name lands
  # in <title>, the brand link and the first <h1> (smoke.sh looks there), the generic prose keeps "app"
  local pg="$r/web/public/pages" f
  for f in index faq privacy terms support; do
    ! grep -q "is a placeholder" "$pg/$f.html" || { echo "$f.html still has the placeholder footer" >&2; return 1; }
    grep -q "Tom&#39;s Notes - contact support@caritos.com" "$pg/$f.html" || { echo "$f.html lacks the new footer" >&2; return 1; }
    grep -q '<a class="brand" href="/">Tom&#39;s Notes</a>' "$pg/$f.html" || { echo "$f.html brand is not the display name" >&2; return 1; }
    ! grep -Eq '<title>[^<]*(^|[^A-Za-z0-9_./-])app([^A-Za-z0-9_-]|$)' "$pg/$f.html" || { echo "$f.html title still has the bare word app" >&2; return 1; }
  done
  grep -q "support@caritos.com" "$pg/support.html"
  ! grep -q "support@example.com" "$pg/support.html"
  grep -q "<title>Tom&#39;s Notes - Notes for Tom</title>" "$pg/index.html"
  grep -q "<h1>Tom&#39;s Notes</h1>" "$pg/index.html" || { echo "home <h1> is not the display name" >&2; return 1; }
  grep -q "<h2>What is Tom&#39;s Notes?</h2>" "$pg/faq.html" || { echo "FAQ heading is not the display name" >&2; return 1; }
  grep -q 'href="/app/">Open the app</a>' "$pg/index.html" || { echo "the /app/ link or the prose 'the app' was rewritten" >&2; return 1; }
  grep -q "example notes app" "$pg/index.html" || { echo "generic prose 'app' was rewritten in index.html" >&2; return 1; }
  grep -q "<title>Tom&#39;s Notes</title>" "$r/web/index.html" || { echo "web/index.html title" >&2; return 1; }
  assert_eq "# Tom&#39;s Notes" "$(sed -n 1p "$r/README.md")" "README title"
  [ -f "$r/web/api/internal/web/app/.gitkeep" ] || { echo "internal/web/app lost" >&2; return 1; }

  git -C "$r" add -A
  git -C "$r" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m start
  # the starter's own fast tier in the copy, and its layout guard in this host-shaped app (ios/ and a root
  # CLAUDE.md of its own, the marker tracked): host mode must accept it
  (cd "$r" && bash web/scripts/layout.test.sh >"$F_ROOT/hostlayout.log" 2>&1) || { grep -v '^ok' "$F_ROOT/hostlayout.log" >&2; return 1; }
  assert_contains "$(cat "$F_ROOT/hostlayout.log")" "host mode"
  (cd "$r" && make -C web test-fast >"$F_ROOT/fast.log" 2>&1) || { tail -n 30 "$F_ROOT/fast.log" >&2; return 1; }

  # deploy-app.sh refuses the placeholder port before any ssh call, and runs the real deploy.sh otherwise
  local r2="$F_ROOT/noport"; mkdir "$r2"
  LOTUS_DIR="$lotus" bash "$SCAFFOLD" "$r2" shop "$DISPLAY_NAME" "d" >/dev/null 2>&1
  # the starter's layout guard must pass on the renamed scaffold, with the extra web/scripts/deploy-app.sh
  git -C "$r2" init -q; git -C "$r2" add -A
  git -C "$r2" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m start
  (cd "$r2" && bash web/scripts/layout.test.sh >"$F_ROOT/layout.log" 2>&1) || { grep -v '^    ok' "$F_ROOT/layout.log" >&2; return 1; }
  make_fakebin "$F_ROOT/bin" ssh 'exit 0'; : > "$F_ROOT/ssh.log"
  ( cd "$r2"; PATH="$F_ROOT/bin:$PATH" FAKE_LOG="$F_ROOT/ssh.log" bash web/scripts/deploy-app.sh me@host --check ) >"$F_ROOT/np.log" 2>&1 && { echo "deploy-app accepted the placeholder port" >&2; return 1; }
  assert_contains "$(cat "$F_ROOT/np.log")" "port"
  [ ! -s "$F_ROOT/ssh.log" ]

  # build the binary and serve it
  (cd "$r" && make -C web build >"$F_ROOT/build.log" 2>&1) || { tail -n 30 "$F_ROOT/build.log" >&2; return 1; }
  # `make -C web build` writes web/dist/<name>.
  bin="$r/web/dist/shop"
  [ -x "$bin" ]
  port=$((20000 + RANDOM % 20000))
  mkdir -p "$F_ROOT/data"
  (cd "$F_ROOT" && DATA_DIR="$F_ROOT/data" ADDR="127.0.0.1:$port" PUBLIC_ORIGIN="http://127.0.0.1:$port" APP_ENV=development \
     exec "$bin" serve >"$F_ROOT/server.log" 2>&1) &
  SERVER_PID=$!
  for _ in $(seq 1 50); do curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1 && break; sleep 0.2; done
  curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null || { cat "$F_ROOT/server.log" >&2; return 1; }

  local appname version
  appname="$(sed -n 's/^export APP_NAME=//p' "$r/web/scripts/deploy-app.sh")"; eval "appname=$appname"
  assert_eq "Tom&#39;s Notes" "$appname"
  version="$(curl -fsS "http://127.0.0.1:$port/healthz?verbose" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')"
  [ -n "$version" ] || version="$(curl -fsS "http://127.0.0.1:$port/healthz" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')"
  APP_NAME="$appname" bash "$r/web/scripts/smoke.sh" "http://127.0.0.1:$port" "$version" >"$F_ROOT/smoke.log" 2>&1 \
    || { cat "$F_ROOT/smoke.log" >&2; return 1; }
}

test_scaffold_with_the_slug_app_keeps_the_module_only_path() {
  local lotus="${LOTUS_DIR:-$STARTER_DIR}" r="$F_ROOT/appslug"
  mkdir -p "$r"; git -C "$r" init -q
  LOTUS_DIR="$lotus" bash "$SCAFFOLD" "$r" app "$DISPLAY_NAME" "d" >"$F_ROOT/appslug.log" 2>&1 || { tail -n 20 "$F_ROOT/appslug.log" >&2; return 1; }
  assert_eq "module github.com/caritos/app" "$(sed -n 1p "$r/web/api/go.mod")"
  [ -d "$r/web/api/cmd/app" ]
  grep -q "<title>Tom&#39;s Notes - d</title>" "$r/web/public/pages/index.html"
  grep -q 'Open the app' "$r/web/public/pages/index.html"
}

test_a_reserved_slug_is_refused_by_the_real_rename_check() {
  local lotus="${LOTUS_DIR:-$STARTER_DIR}" r="$F_ROOT/reserved" rc=0 out
  mkdir -p "$r"
  out="$(LOTUS_DIR="$lotus" bash "$SCAFFOLD" "$r" verify "V" "d" 2>&1)" || rc=$?
  assert_eq 2 "$rc"
  assert_contains "$out" "verify"
  [ -z "$(ls -A "$r")" ]
}
