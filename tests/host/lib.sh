# shellcheck shell=bash
# Shared by host/'s tests, test.sh (apply.sh against a fake root) and bootstrap-test.sh
# (bootstrap.sh in a container). A test file sources this, defines test_* functions and
# run_one, then calls: run_tests "$@"

# The commands apply.sh and bootstrap.sh need a real kernel, init or apt for, which
# stub.sh stands in for.
STUBBED=(systemctl timedatectl apt-get apt-mark dpkg-query fallocate mkswap swapon swapoff sysctl docker)

# make_stubs DIR STUB_SH [COMMAND...]: a wrapper in DIR for each stubbed command, plus any
# COMMANDs, that runs STUB_SH with STUB_NAME set. Put DIR first on PATH.
make_stubs() {
  local dir="$1" stub="$2" cmd
  shift 2
  mkdir -p "$dir"
  for cmd in "${STUBBED[@]}" "$@"; do
    printf '#!/bin/sh\nSTUB_NAME=%s exec bash %q "$@"\n' "$cmd" "$stub" > "$dir/$cmd"
    chmod +x "$dir/$cmd"
  done
}

# snapshot DIR...: every regular file and symlink under the DIRs, with its owner, mode
# and checksum, to compare before and after. Skips the `-` backups useradd leaves in /etc.
snapshot() {
  find "$@" \( -type f -o -type l \) ! -name '*-' -printf '%p|%l|%u:%g|%m\n' | sort |
    while IFS='|' read -r p l owner mode; do
      echo "$p ${l:+-> $l }$owner $mode $([ -f "$p" ] && [ ! -L "$p" ] && md5sum < "$p")"
    done
}

fail() { echo "    $*"; return 1; }
assert_eq() { [ "$1" = "$2" ] || fail "expected [$2], got [$1]${3:+ ($3)}"; }

# run_tests [FILTER]: runs each test_* function whose name contains FILTER through
# run_one NAME, which the test file defines. A failing test's output is shown. File
# descriptor 3 reaches the terminal even for a passing test.
run_tests() {
  local passed=0 failed=0 t out
  out="$(mktemp)"
  exec 3>&1
  for t in $(declare -F | awk '{print $3}' | grep '^test_' | grep -- "${1:-}"); do
    if run_one "$t" > "$out" 2>&1; then
      echo "ok   $t"
      passed=$((passed + 1))
    else
      echo "FAIL $t"
      sed 's/^/    | /' "$out" | tail -30
      failed=$((failed + 1))
    fi
  done
  rm -f "$out"
  echo "$passed passed, $failed failed"
  [ "$failed" = 0 ]
}
