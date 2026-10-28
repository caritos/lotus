#!/bin/bash
# Full tier: scaffold from the REAL ~/src/goweb into a temp repo that already has ios/ and a root
# CLAUDE.md, run goweb's own fast tier there, run its layout guard (scripts/layout.test.sh) on a fresh scaffold, build the binary, serve it locally and
# run goweb's scripts/smoke.sh against it with APP_NAME as written by scripts/deploy-app.sh.
# Needs Node (web/.nvmrc under ~/.nvm, or on PATH), pnpm and Go. goweb's `--check` logs in over ssh and
# cannot run offline; the placeholder-port refusal before any ssh call is tested here and in the fast tier.
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAFFOLD="$SKILL_DIR/scripts/scaffold.sh"
F_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nwa-full.XXXXXX")"
SERVER_PID=""
trap '[ -z "$SERVER_PID" ] || { kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; }; rm -rf "$F_ROOT"' EXIT
DISPLAY_NAME="Tom's Notes"

test_scaffold_from_real_goweb_builds_serves_and_passes_smoke() {
  local goweb="${GOWEB_DIR:-$HOME/src/goweb}" r="$F_ROOT/repo" before out port pid
  [ -e "$goweb/.git" ] || { echo "goweb not found at $goweb" >&2; return 1; }   # -e: a linked worktree's .git is a file
  before="$(git -C "$goweb" status --porcelain)"
  mkdir -p "$r/ios/App"; echo swift > "$r/ios/App/main.swift"; printf '# Mine\n' > "$r/CLAUDE.md"
  git -C "$r" init -q
  out="$(GOWEB_DIR="$goweb" bash "$SCAFFOLD" "$r" shop "$DISPLAY_NAME" "Notes for Tom" --port 8123 2>&1)" || { echo "$out" >&2; return 1; }
  assert_contains "$out" "skipped ios/"
  assert_eq "swift" "$(cat "$r/ios/App/main.swift")"
  [ ! -e "$r/ios/README.md" ]
  assert_contains "$(cat "$r/CLAUDE.md")" "web/CLAUDE.md"
  [ -f "$r/web/CLAUDE.md" ]
  assert_eq "$before" "$(git -C "$goweb" status --porcelain)" "goweb untouched"

  # leftover "goweb" anywhere except the origin file and goweb's own design history
  local left; left="$(grep -rli goweb "$r" --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=superpowers --exclude=.goweb-origin || true)"
  [ -z "$left" ] || { echo "goweb left in: $left" >&2; return 1; }

  # the replacement patterns must match goweb's real page text, not only the fixture's
  local pg="$r/web/api/internal/web/pages" f
  for f in index faq privacy terms support; do
    ! grep -q "is a placeholder name" "$pg/$f.html" || { echo "$f.html still has the placeholder footer" >&2; return 1; }
    grep -q "Tom&#39;s Notes - contact support@caritos.com" "$pg/$f.html" || { echo "$f.html lacks the new footer" >&2; return 1; }
  done
  grep -q "support@caritos.com" "$pg/support.html"
  ! grep -q "support@example.com" "$pg/support.html"
  grep -q "<title>Tom&#39;s Notes - Notes for Tom</title>" "$pg/index.html"

  git -C "$r" add -A
  git -C "$r" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m start
  # goweb's own fast tier in the copy. Its layout guard is run on the fresh scaffold below: next to a real
  # ios/ without README.md and a root CLAUDE.md of the host it fails by design (it assumes goweb's own).
  (cd "$r" && make test-fast >"$F_ROOT/fast.log" 2>&1) || { tail -n 30 "$F_ROOT/fast.log" >&2; return 1; }

  # deploy-app.sh refuses the placeholder port before any ssh call, and runs the real deploy.sh otherwise
  local r2="$F_ROOT/noport"; mkdir "$r2"
  GOWEB_DIR="$goweb" bash "$SCAFFOLD" "$r2" shop "$DISPLAY_NAME" "d" >/dev/null 2>&1
  # goweb's layout guard must pass on the renamed scaffold, with the extra scripts/deploy-app.sh
  git -C "$r2" init -q; git -C "$r2" add -A
  git -C "$r2" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m start
  (cd "$r2" && bash scripts/layout.test.sh >"$F_ROOT/layout.log" 2>&1) || { grep -v '^    ok' "$F_ROOT/layout.log" >&2; return 1; }
  make_fakebin "$F_ROOT/bin" ssh 'exit 0'; : > "$F_ROOT/ssh.log"
  ( cd "$r2"; PATH="$F_ROOT/bin:$PATH" FAKE_LOG="$F_ROOT/ssh.log" bash scripts/deploy-app.sh me@host --check ) >"$F_ROOT/np.log" 2>&1 && { echo "deploy-app accepted the placeholder port" >&2; return 1; }
  assert_contains "$(cat "$F_ROOT/np.log")" "port"
  [ ! -s "$F_ROOT/ssh.log" ]

  # build the binary and serve it
  (cd "$r" && make build >"$F_ROOT/build.log" 2>&1) || { tail -n 30 "$F_ROOT/build.log" >&2; return 1; }
  # goweb's `make build` writes dist/<name> (newer layout) or ./<name> (older); accept either.
  bin="$r/dist/shop"; [ -x "$bin" ] || bin="$r/shop"
  [ -x "$bin" ]
  port=$((20000 + RANDOM % 20000))
  mkdir -p "$F_ROOT/data"
  (cd "$F_ROOT" && DATA_DIR="$F_ROOT/data" ADDR="127.0.0.1:$port" PUBLIC_ORIGIN="http://127.0.0.1:$port" APP_ENV=development \
     exec "$bin" serve >"$F_ROOT/server.log" 2>&1) &
  SERVER_PID=$!
  for _ in $(seq 1 50); do curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1 && break; sleep 0.2; done
  curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null || { cat "$F_ROOT/server.log" >&2; return 1; }

  local appname version
  appname="$(sed -n 's/^export APP_NAME=//p' "$r/scripts/deploy-app.sh")"; eval "appname=$appname"
  assert_eq "Tom&#39;s Notes" "$appname"
  version="$(curl -fsS "http://127.0.0.1:$port/healthz?verbose" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')"
  [ -n "$version" ] || version="$(curl -fsS "http://127.0.0.1:$port/healthz" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')"
  APP_NAME="$appname" bash "$r/scripts/smoke.sh" "http://127.0.0.1:$port" "$version" >"$F_ROOT/smoke.log" 2>&1 \
    || { cat "$F_ROOT/smoke.log" >&2; return 1; }
}
