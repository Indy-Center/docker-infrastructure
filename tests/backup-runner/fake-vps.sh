# The fake VPS the backup runner's tests run against, shared by test.sh (the hourly
# runner) and helpers-test.sh (the helper commands). Each test builds a fresh one in a
# temp folder: apps, a schedule file, secrets with a test age key, a local folder standing
# in for R2 and its media buckets, and a fake Discord and status page.
#
# A test file sources this, defines test_* functions, then calls: run_tests "$@"

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
here="$repo/tests/backup-runner"

# ---------------------------------------------------------------------------
# The fake VPS
# ---------------------------------------------------------------------------

# Builds a fresh fake VPS in $T and starts the fake endpoint.
setup() {
  T="$(mktemp -d)"
  mkdir -p "$T/apps" "$T/staging" "$T/r2/indy-center-backups" "$T/runner/secrets" "$T/endpoint"
  python3 "$here/fake-endpoint.py" "$T/endpoint" &
  endpoint_pid=$!
  for _ in $(seq 50); do [ -f "$T/endpoint/port" ] && break; sleep 0.1; done
  local url
  url="http://127.0.0.1:$(cat "$T/endpoint/port")"

  # rclone's alias backend makes r2:indy-center-backups a plain folder on disk.
  printf '[r2]\ntype = alias\nremote = %s\n' "$T/r2" > "$T/runner/secrets/rclone.conf"
  age-keygen -o "$T/runner/secrets/age.key" 2>/dev/null
  echo "$url/report" > "$T/runner/secrets/report-webhook.url"
  echo "$url/alerts" > "$T/runner/secrets/alert-webhook.url"
  : > "$T/schedule.conf"
  # One empty media bucket, so the media copy has something to copy and stays quiet.
  mkdir -p "$T/r2/test-media"
  echo "test-media" > "$T/media.conf"
}

teardown() {
  kill "$endpoint_pid" 2>/dev/null
  wait "$endpoint_pid" 2>/dev/null
  # KEEP_FAKE_VPS=1 leaves the fake VPS behind, to look at what a test produced.
  if [ -n "${KEEP_FAKE_VPS:-}" ]; then echo "    kept $T"; else rm -rf "$T"; fi
}

# An app whose recipe writes one file with known contents.
app_working() {
  mkdir -p "$T/apps/$1"
  cat > "$T/apps/$1/backup.sh" <<EOF
echo "data of $1" > "\$1/$1.txt"
EOF
  touch "$T/apps/$1/restore.sh"
}

# An app whose recipe fails.
app_failing() {
  mkdir -p "$T/apps/$1"
  printf 'echo "pg_dump: connection refused" >&2\nexit 1\n' > "$T/apps/$1/backup.sh"
  touch "$T/apps/$1/restore.sh"
}

# The messages the fake Discord received on one webhook (report or alerts), in order.
# Always succeeds, so `messages alerts | grep -q …` passes on grep's answer alone even
# when grep stops reading early.
messages() {
  local f
  for f in $(ls "$T/endpoint/$1"/*.body 2>/dev/null | sort -V); do
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["content"])' "$f" 2>/dev/null || true
  done
}

message_count() { ls "$T/endpoint/$1"/*.body 2>/dev/null | grep -c . || true; }

# The settings that point the runner and the helpers at the fake VPS, for `env`.
fake_vps_env() {
  echo "BACKUP_RUNNER_HOME=$T/runner" "BACKUP_SCHEDULE=$T/schedule.conf" \
    "BACKUP_MEDIA=$T/media.conf" "APPS_DIR=$T/apps" "STAGING_DIR=$T/staging"
}

# Runs the runner once, as the given UTC time, against the fake VPS.
run_at() {
  env $(fake_vps_env) BACKUP_RUNNER_NOW="$1" \
    bash "$repo/backup-runner/run-backups.sh" > "$T/run.out" 2>&1
  echo $? > "$T/run.status"
}

# A media bucket for the media copy to copy from: a folder in the fake R2, listed in
# media.conf.
media_bucket() {
  mkdir -p "$T/r2/$1"
  echo "$1" >> "$T/media.conf"
}

# Lists the files in one tier/app folder of the fake bucket, by name.
backups_in() { ls "$T/r2/indy-center-backups/$1" 2>/dev/null; }

# Decrypts one backup with the test key and prints it.
decrypt() { age -d -i "$T/runner/secrets/age.key" "$T/r2/indy-center-backups/$1"; }

# ---------------------------------------------------------------------------
# Assertions: each prints what went wrong and returns non-zero.
# ---------------------------------------------------------------------------

fail() { echo "    $*"; return 1; }

assert_eq() { [ "$1" = "$2" ] || fail "expected [$2], got [$1]${3:+ ($3)}"; }

assert_count() {
  local n
  n="$(backups_in "$1" | grep -c . || true)"
  [ "$n" = "$2" ] || fail "expected $2 file(s) in $1, found $n: $(backups_in "$1" | tr '\n' ' ')"
}

# ---------------------------------------------------------------------------
# Runs every test function (or those matching $1), each on its own fake VPS.
# ---------------------------------------------------------------------------

run_tests() {
  local passed=0 failed=0 t
  for t in $(declare -F | awk '{print $3}' | grep '^test_' | grep -- "${1:-}"); do
    setup
    if ( set -e; "$t" ); then
      echo "ok   $t"
      passed=$((passed + 1))
    else
      echo "FAIL $t"
      cat "$T/run.out" "$T/runner/logs/runner.log" 2>/dev/null | sed 's/^/    | /' | tail -20
      failed=$((failed + 1))
    fi
    teardown
  done
  echo "$passed passed, $failed failed"
  [ "$failed" = 0 ]
}
