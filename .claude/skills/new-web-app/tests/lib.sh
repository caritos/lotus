#!/bin/bash
# Shared shell test helpers. Source this from *.test.sh files.
# A failed assertion prints a message and returns 1; test functions run under `set -e`
# in the runner, so the first failed assertion fails the test.

PATH="/usr/bin:/bin:$PATH"

assert_eq() {  # assert_eq <expected> <actual> [message]
  if [ "$1" != "$2" ]; then
    echo "  FAIL${3:+ ($3)}: expected [$1] got [$2]" >&2; return 1
  fi
}

assert_contains() {  # assert_contains <haystack> <needle> [message]
  case "$1" in *"$2"*) ;; *) echo "  FAIL${3:+ ($3)}: expected output to contain [$2]; got [$1]" >&2; return 1 ;; esac
}

assert_not_contains() {  # assert_not_contains <haystack> <needle> [message]
  case "$1" in *"$2"*) echo "  FAIL${3:+ ($3)}: expected output NOT to contain [$2]; got [$1]" >&2; return 1 ;; *) ;; esac
}

assert_fails() {  # assert_fails <command...>   (passes when the command exits non-zero)
  if "$@" >/dev/null 2>&1; then
    echo "  FAIL: expected command to fail: $*" >&2; return 1
  fi
}

# make_fakebin <dir> <name> <script>
# Creates executable <dir>/<name>. On each call it appends its argv (one line) to $FAKE_LOG,
# then runs <script> (shell snippet; args are $1.. ). Put <dir> first on PATH to shadow the real tool.
make_fakebin() {
  local dir="$1" name="$2" script="${3:-}"
  mkdir -p "$dir"
  {
    echo '#!/bin/bash'
    echo "echo \"$name \$*\" >> \"\${FAKE_LOG:-/dev/null}\""
    echo "$script"
  } > "$dir/$name"
  chmod +x "$dir/$name"
}
