# shellcheck shell=bash
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
  # The server's name, which the deploy writes from build-and-deploy.yml's server list.
  echo "testbox" > "$T/runner/server"
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

# --- The server's own state: host/ and a needed reboot ---------------------------------
# A fresh fake VPS has neither ~/host/ nor /var/run/reboot-required: fake_vps_env points
# the runner at $T/host and $T/run, so this machine's own never leak in.

# A ~/host/ whose apply.sh --check prints the given text and exits with the given code.
#   host_check_says <exit code> <output>
host_check_says() {
  mkdir -p "$T/host"
  printf '%s\n' "$2" > "$T/host/check-output"
  printf 'cat "%s"\nexit %s\n' "$T/host/check-output" "$1" > "$T/host/apply.sh"
}

# Ubuntu's reboot-required file, dated the given UTC day, with the given packages in
# reboot-required.pkgs, one per line (Ubuntu repeats a package that asks twice).
#   reboot_needed_since <YYYY-MM-DD> [package…]
reboot_needed_since() {
  mkdir -p "$T/run"
  echo "*** System restart required ***" > "$T/run/reboot-required"
  touch -d "$1T05:00:00Z" "$T/run/reboot-required"
  shift
  if [ $# -gt 0 ]; then printf '%s\n' "$@" > "$T/run/reboot-required.pkgs"; fi
}

# A fake server root matching host/ as apply.sh --check sees it, with the commands it
# needs stubbed by tests/host/stub.sh, and Docker's packages held, as they are on a real
# server. The repo's real host/ is copied to $T/host, so the runner runs the real check.
# The stubs go in the runner's own bin/, first on its PATH. Exports what the check needs
# (HOST_ROOT, STUB_STATE, STUB_LOG), so call it from the test itself, not a subshell.
host_matching_the_repo() {
  local r="$T/server-root" s="$T/stub-state" f p
  cp -r "$repo/host" "$T/host"
  # shellcheck source=tests/host/lib.sh
  (source "$repo/tests/host/lib.sh"; make_stubs "$T/runner/bin" "$repo/tests/host/stub.sh")
  export HOST_ROOT="$r" STUB_STATE="$s" STUB_LOG="$T/stub-calls"

  mkdir -p "$r/etc"
  printf 'NAME="Ubuntu"\nVERSION_ID="26.04"\nVERSION_CODENAME=resolute\n' > "$r/etc/os-release"
  (cd "$repo/host/files" && find . -type f) | while read -r f; do
    f="${f#.}"
    mkdir -p "$(dirname "$r$f")"
    sed 's/@VERSION_CODENAME@/resolute/g' "$repo/host/files$f" > "$r$f"
  done
  ln -s /usr/share/zoneinfo/Etc/UTC "$r/etc/localtime"
  truncate -s 4G "$r/swapfile"
  chmod 600 "$r/swapfile"
  echo "/swapfile none swap sw 0 0" > "$r/etc/fstab"
  mkdir -p "$r/home/deploy"/{traefik,apps,backup-runner,backups}

  mkdir -p "$s/installed" "$s/held" "$s/active" "$s/networks"
  for p in docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; do
    touch "$s/installed/$p" "$s/held/$p"
  done
  touch "$s/installed/unattended-upgrades" "$s/installed/chrony" "$s/active/chrony" \
    "$s/networks/traefik-shared"
  echo "$r/swapfile" > "$s/swaps"
}

# --- Fake CMS backups, for the restore check and the scratch database ------------------
# These need Docker and a real Postgres 17. A test that uses them starts with
#   have_docker || return 0

# Test containers have their own names (and the scratch database its own port), so they
# never meet real ones on the same machine. The dump maker's name is this test file's
# own, so test.sh and helpers-test.sh can run at the same time.
export BACKUP_RESTORE_CHECK_CONTAINER=backups-restore-check-test
export BACKUP_SCRATCH_CONTAINER=backups-scratch-cms-test BACKUP_SCRATCH_PORT=25432
DUMP_MAKER="backups-test-dump-maker-$$"

# Whether Docker is usable here. Without it the tests that need it pass trivially, except
# in CI (GitHub sets CI=true), where they must run: there, no Docker fails the test (each
# test runs in its own subshell, so exit ends only the test).
have_docker() {
  docker info > /dev/null 2>&1 && return 0
  if [ "${CI:-}" = true ]; then
    echo "    no Docker, and in CI this test must run"
    exit 1
  fi
  echo "    skipped: no Docker"
  return 1
}

# A fake CMS whose recipe writes the given file as its backup.
cms_backing_up() {
  mkdir -p "$T/apps/payload"
  cp "$1" "$T/fake-backup-file"
  echo "cp \"$T/fake-backup-file\" \"\$1/$(basename "$1")\"" > "$T/apps/payload/backup.sh"
  touch "$T/apps/payload/restore.sh"
}

# Makes a pg_dump custom-format dump of a small CMS-like database with Postgres 17 itself,
# at the given path: one table, pages, with one row. The table is owned by a "payload"
# role, as the live CMS's tables are; a throwaway database has no such role, so a load
# must leave ownership out.
make_cms_dump() {
  # The runner's own start_postgres, sourced in a subshell so lib.sh's settings stay there.
  local why
  why="$(source "$repo/backup-runner/lib.sh"; start_postgres "$DUMP_MAKER" x)" \
    || fail "the dump maker's Postgres: $why" || return 1
  docker exec "$DUMP_MAKER" psql -q -U postgres -d payload -c "CREATE ROLE payload; CREATE TABLE pages (slug text); INSERT INTO pages VALUES ('sops'); ALTER TABLE pages OWNER TO payload;"
  docker exec "$DUMP_MAKER" pg_dump -U postgres -Fc payload > "$1"
  docker rm -f -v "$DUMP_MAKER" > /dev/null
}

# A fake CMS whose recipe writes payload.tar as payload's does: the given dump as
# payload.dump, and the given row counts (printf text: "table\trows\n" lines) as
# row-counts.tsv.
#   cms_backup_of <dump> <counts>
cms_backup_of() {
  mkdir -p "$T/pack"
  cp "$1" "$T/pack/payload.dump"
  # The counts are a format string on purpose, so a test can write \t and \n.
  # shellcheck disable=SC2059
  printf "$2" > "$T/pack/row-counts.tsv"
  tar -cf "$T/payload.tar" -C "$T/pack" payload.dump row-counts.tsv
  cms_backing_up "$T/payload.tar"
}

# The same, with make_cms_dump's dump: a good backup, whatever the counts say.
#   cms_backup_with_counts <counts>
cms_backup_with_counts() {
  make_cms_dump "$T/good.dump" || return 1
  cms_backup_of "$T/good.dump" "$1"
}

# Whether a container exists, running or not.
container_exists() { [ -n "$(docker ps -aq -f name="^$1\$")" ]; }

# Removes every test container when a test ends, however it ends.
remove_test_containers_on_exit() {
  trap 'docker rm -f -v "$BACKUP_RESTORE_CHECK_CONTAINER" "$BACKUP_SCRATCH_CONTAINER" "$DUMP_MAKER" > /dev/null 2>&1' EXIT
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

# The newest message the fake Discord received on one webhook.
last_message() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["content"])' \
    "$T/endpoint/$1/$(message_count "$1").body" 2>/dev/null || true
}

# The settings that point the runner and the helpers at the fake VPS, for `env`.
fake_vps_env() {
  echo "BACKUP_RUNNER_HOME=$T/runner" "BACKUP_SCHEDULE=$T/schedule.conf" \
    "BACKUP_MEDIA=$T/media.conf" "APPS_DIR=$T/apps" "STAGING_DIR=$T/staging" \
    "HOST_DIR=$T/host" "REBOOT_REQUIRED=$T/run/reboot-required"
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
