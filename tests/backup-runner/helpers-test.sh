#!/usr/bin/env bash
# Tests for the helper commands (backup-runner/backups.sh), on the same fake VPS as the
# runner's tests (fake-vps.sh). Backups are made by the real runner, then each command
# is run the way the maintainer would, and the test checks what it printed and did.
#
#   bash tests/backup-runner/helpers-test.sh          # every test
#   bash tests/backup-runner/helpers-test.sh restore  # tests whose name contains "restore"
#
# Needs what test.sh needs. The scratch CMS tests also need Docker, and are skipped
# without it.
set -uo pipefail
source "$(dirname "$0")/fake-vps.sh"

# Runs one helper command against the fake VPS. Its output is also kept in $T/run.out,
# which a failing test prints.
backups() {
  env $(fake_vps_env) bash "$repo/backup-runner/backups.sh" "$@" 2>&1 | tee "$T/run.out"
  return "${PIPESTATUS[0]}"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test_list_shows_an_apps_backups_oldest_first_with_their_tiers() {
  app_working cms
  echo "cms 6 14" > "$T/schedule.conf"
  run_at 2026-10-20T07:00:00Z
  run_at 2026-10-20T13:00:00Z
  local out
  out="$(backups list cms)" || fail "list failed: $out" || return 1
  echo "$out" | grep -Eq '^2026-10-20T070000Z-cms\.txt\.age +[0-9.]+ ?[KM]?i?B +frequent daily monthly$' \
    || fail "first backup's line: $out" || return 1
  echo "$out" | grep -Eq '^2026-10-20T130000Z-cms\.txt\.age +[0-9.]+ ?[KM]?i?B +frequent$' \
    || fail "second backup's line: $out" || return 1
  # Oldest first, so the newest is the last line.
  echo "$out" | tail -n 1 | grep -q 130000Z || fail "newest is not last: $out"
}

test_list_of_an_app_with_no_backups_says_so() {
  local out
  out="$(backups list nothing)" && fail "list should fail: $out" && return 1
  echo "$out" | grep -q "No backups of nothing" || fail "unexpected output: $out"
}

test_fetch_downloads_and_decrypts_a_chosen_backup() {
  app_working cms
  echo "cms 6 14" > "$T/schedule.conf"
  run_at 2026-10-20T07:00:00Z
  echo 'echo "later data" > "$1/cms.txt"' > "$T/apps/cms/backup.sh"
  run_at 2026-10-20T13:00:00Z
  mkdir "$T/out"
  # The start of a name is enough, as long as only one backup matches.
  backups fetch cms 2026-10-20T07 "$T/out" > /dev/null || fail "fetch failed" || return 1
  assert_eq "$(cat "$T/out/2026-10-20T070000Z-cms.txt")" "data of cms" || return 1
  # Only the person running it can read the decrypted copy.
  assert_eq "$(stat -c %a "$T/out/2026-10-20T070000Z-cms.txt")" 600 "mode"
}

test_fetch_latest_gets_the_newest_backup() {
  app_working cms
  echo "cms 6 14" > "$T/schedule.conf"
  run_at 2026-10-20T07:00:00Z
  echo 'echo "later data" > "$1/cms.txt"' > "$T/apps/cms/backup.sh"
  run_at 2026-10-20T13:00:00Z
  mkdir "$T/out"
  backups fetch cms latest "$T/out" > /dev/null || fail "fetch failed" || return 1
  assert_eq "$(cat "$T/out/2026-10-20T130000Z-cms.txt")" "later data"
}

test_fetch_refuses_a_name_that_matches_more_than_one_backup() {
  app_working cms
  echo "cms 6 14" > "$T/schedule.conf"
  run_at 2026-10-20T07:00:00Z
  run_at 2026-10-20T13:00:00Z
  mkdir "$T/out"
  local out
  out="$(backups fetch cms 2026-10-20 "$T/out")" && fail "fetch should fail: $out" && return 1
  echo "$out" | grep -q "matches 2 backups" || fail "unexpected output: $out" || return 1
  assert_eq "$(ls -A "$T/out")" "" "nothing fetched"
}

test_fetch_never_overwrites_a_file() {
  app_working cms
  run_at 2026-10-20T07:00:00Z
  mkdir "$T/out"
  echo "mine" > "$T/out/2026-10-20T070000Z-cms.txt"
  backups fetch cms latest "$T/out" > /dev/null && fail "fetch should fail" && return 1
  assert_eq "$(cat "$T/out/2026-10-20T070000Z-cms.txt")" "mine"
}

test_now_backs_up_into_frequent_the_way_the_runner_does() {
  app_working cms
  BACKUP_RUNNER_NOW=2026-10-20T05:30:00Z backups now cms > /dev/null || fail "now failed" || return 1
  assert_eq "$(backups_in frequent/cms)" "2026-10-20T053000Z-cms.txt.age" || return 1
  assert_eq "$(decrypt frequent/cms/2026-10-20T053000Z-cms.txt.age)" "data of cms" || return 1
  # Never promoted: daily/ and monthly/ keep the scheduled backups.
  assert_count daily/cms 0 || return 1
  assert_count monthly/cms 0 || return 1
  assert_eq "$(ls -A "$T/staging")" "" "staging left behind" || return 1
  grep -q "cms: backed up 2026-10-20T053000Z-cms.txt.age" "$T/runner/logs/runner.log" \
    || fail "not in the runner's log"
}

test_now_leaves_the_schedule_alone() {
  app_working cms
  run_at 2026-10-20T07:00:00Z
  BACKUP_RUNNER_NOW=2026-10-20T09:00:00Z backups now cms > /dev/null
  run_at 2026-10-21T07:00:00Z
  assert_eq "$(backups_in daily/cms | tr '\n' ' ')" \
    "2026-10-20T070000Z-cms.txt.age 2026-10-21T070000Z-cms.txt.age "
}

test_now_says_why_when_the_recipe_fails_and_sends_no_alert() {
  app_failing cms
  local out
  out="$(backups now cms)" && fail "now should fail: $out" && return 1
  echo "$out" | grep -q "connection refused" || fail "the recipe's error is not shown: $out" || return 1
  assert_eq "$(message_count alerts)" 0 "alerts"
}

test_now_stops_at_an_app_with_no_recipe() {
  mkdir -p "$T/apps/stateless"
  touch "$T/apps/stateless/no-backup"
  local out
  out="$(backups now stateless)" && fail "now should fail: $out" && return 1
  echo "$out" | grep -q "stateless has no backup.sh" || fail "unexpected output: $out"
}

# An app whose restore.sh writes down what it was given: the folder it ran in, and the
# contents of the file it was passed.
app_restorable() {
  app_working "$1"
  cat > "$T/apps/$1/restore.sh" <<EOF
pwd > "$T/restore-ran-in"
cat "\$1" > "$T/restore-got"
EOF
}

test_restore_runs_the_apps_restore_with_the_decrypted_backup() {
  app_restorable cms
  echo "cms 6 14" > "$T/schedule.conf"
  run_at 2026-10-20T07:00:00Z
  echo 'echo "later data" > "$1/cms.txt"' > "$T/apps/cms/backup.sh"
  run_at 2026-10-20T13:00:00Z
  local out
  out="$(echo cms | backups restore cms 2026-10-20T07)" || fail "restore failed: $out" || return 1
  assert_eq "$(cat "$T/restore-got")" "data of cms" || return 1
  assert_eq "$(cat "$T/restore-ran-in")" "$T/apps/cms" "restore.sh's folder" || return 1
  # The decrypted copy is gone once the restore is done.
  assert_eq "$(ls -A "$T/staging")" "" "staging left behind" || return 1
  grep -q "cms: restore.sh finished" "$T/runner/logs/runner.log" || fail "not in the runner's log"
}

test_restore_asks_first_and_stops_on_any_other_answer() {
  app_restorable cms
  run_at 2026-10-20T07:00:00Z
  local out
  out="$(echo y | backups restore cms latest)" && fail "restore should stop: $out" && return 1
  echo "$out" | grep -q "replaces cms's live data" || fail "does not say what it will do: $out" || return 1
  [ ! -e "$T/restore-got" ] || fail "restore.sh ran without the app's name typed" || return 1
  assert_eq "$(ls -A "$T/staging")" "" "staging left behind"
}

test_restore_stops_at_an_app_with_no_restore_script() {
  app_working cms
  rm "$T/apps/cms/restore.sh"
  run_at 2026-10-20T07:00:00Z
  local out
  out="$(echo cms | backups restore cms latest)" && fail "restore should stop: $out" && return 1
  echo "$out" | grep -q "cms has no restore.sh" || fail "unexpected output: $out" || return 1
  echo "$out" | grep -q "Downloading" && fail "it downloaded before stopping: $out" && return 1
  return 0
}

test_restore_that_fails_says_so() {
  app_working cms
  printf 'echo "database is busy" >&2\nexit 3\n' > "$T/apps/cms/restore.sh"
  run_at 2026-10-20T07:00:00Z
  local out
  out="$(echo cms | backups restore cms latest)" && fail "restore should fail: $out" && return 1
  echo "$out" | grep -q "database is busy" || fail "restore.sh's error is not shown: $out" || return 1
  echo "$out" | grep -q "restore.sh exited 3" || fail "unexpected output: $out" || return 1
  assert_eq "$(ls -A "$T/staging")" "" "staging left behind"
}

test_media_find_and_get_bring_back_a_file_deleted_from_the_cms() {
  media_bucket payload-media
  mkdir -p "$T/r2/payload-media/courses"
  echo "plane" > "$T/r2/payload-media/courses/Plane.png"
  echo "tower" > "$T/r2/payload-media/tower.png"
  run_at 2026-10-20T07:00:00Z
  rm "$T/r2/payload-media/courses/Plane.png"

  local out
  out="$(backups media-find plane)" || fail "media-find failed: $out" || return 1
  # Any case matches, and only the matching file is listed.
  assert_eq "$(echo "$out" | grep -v '^Files')" "payload-media/courses/Plane.png" || return 1

  mkdir "$T/out"
  out="$(backups media-get payload-media/courses/Plane.png "$T/out")" || fail "media-get failed: $out" || return 1
  assert_eq "$(cat "$T/out/Plane.png")" "plane" || return 1
  # It says where the file goes back.
  echo "$out" | grep -q "payload-media.*courses/Plane.png" || fail "no put-back instructions: $out"
}

test_media_get_of_a_file_not_in_the_copy_says_so() {
  local out
  out="$(backups media-get payload-media/nothing.png "$T")" && fail "media-get should fail: $out" && return 1
  echo "$out" | grep -q "No file media/payload-media/nothing.png" || fail "unexpected output: $out"
}

# The scratch CMS tests use their own container name and port, so they never meet a real
# scratch database on the same machine.
export BACKUP_SCRATCH_CONTAINER=backups-scratch-cms-test BACKUP_SCRATCH_PORT=25432

# Whether Docker is usable here; the scratch CMS tests pass trivially without it.
have_docker() {
  docker info > /dev/null 2>&1 && return 0
  echo "    skipped: no Docker"
  return 1
}

# Runs SQL in the scratch database and prints the result, one row per line.
scratch_sql() { docker exec "$BACKUP_SCRATCH_CONTAINER" psql -U postgres -tAc "$1" payload; }

# A fake CMS whose recipe writes the given file as its backup.
cms_backing_up() {
  mkdir -p "$T/apps/payload"
  cp "$1" "$T/fake-backup-file"
  echo "cp \"$T/fake-backup-file\" \"\$1/$(basename "$1")\"" > "$T/apps/payload/backup.sh"
  touch "$T/apps/payload/restore.sh"
}

test_scratch_cms_loads_a_plain_sql_backup_and_is_removed_on_request() {
  have_docker || return 0
  trap 'docker rm -f -v "$BACKUP_SCRATCH_CONTAINER" > /dev/null 2>&1' EXIT
  printf "CREATE TABLE courses (title text);\nINSERT INTO courses VALUES ('Tower 101');\n" > "$T/payload.sql"
  cms_backing_up "$T/payload.sql"
  run_at 2026-10-20T07:00:00Z

  local out
  out="$(backups scratch-cms latest)" || fail "scratch-cms failed: $out" || return 1
  assert_eq "$(scratch_sql 'select title from courses')" "Tower 101" || return 1
  echo "$out" | grep -q "docker exec -it $BACKUP_SCRATCH_CONTAINER psql" || fail "no way to connect: $out" || return 1
  echo "$out" | grep -q "127.0.0.1:25432" || fail "no port to connect on: $out" || return 1
  assert_eq "$(ls -A "$T/staging")" "" "decrypted backup left behind" || return 1

  # Only one at a time.
  out="$(backups scratch-cms latest)" && fail "a second scratch-cms should stop: $out" && return 1
  echo "$out" | grep -q "already" || fail "unexpected output: $out" || return 1

  backups scratch-cms remove > /dev/null || fail "remove failed" || return 1
  [ -z "$(docker ps -aq -f name="^$BACKUP_SCRATCH_CONTAINER\$")" ] || fail "the container is still there"
}

test_scratch_cms_loads_a_custom_format_dump_inside_an_archive() {
  have_docker || return 0
  trap 'docker rm -f -v "$BACKUP_SCRATCH_CONTAINER" > /dev/null 2>&1' EXIT
  # A pg_dump custom-format dump, made with Postgres 17 itself, packed in a .tar.gz next to
  # a row-count file, as a recipe might ship it.
  docker run -d --name "$BACKUP_SCRATCH_CONTAINER" -e POSTGRES_PASSWORD=x -e POSTGRES_DB=payload postgres:17 > /dev/null
  until docker exec "$BACKUP_SCRATCH_CONTAINER" pg_isready -h 127.0.0.1 -U postgres -q; do sleep 1; done
  scratch_sql "CREATE TABLE pages (slug text); INSERT INTO pages VALUES ('sops');" > /dev/null
  mkdir "$T/pack"
  docker exec "$BACKUP_SCRATCH_CONTAINER" pg_dump -U postgres -Fc payload > "$T/pack/payload.dump"
  echo '{"pages": 1}' > "$T/pack/counts.json"
  tar -czf "$T/payload.tar.gz" -C "$T/pack" payload.dump counts.json
  docker rm -f -v "$BACKUP_SCRATCH_CONTAINER" > /dev/null
  cms_backing_up "$T/payload.tar.gz"
  run_at 2026-10-20T07:00:00Z

  local out
  out="$(backups scratch-cms latest)" || fail "scratch-cms failed: $out" || return 1
  assert_eq "$(scratch_sql 'select slug from pages')" "sops"
}

# Every file on the fake VPS with its size and time, to show a command changed nothing.
# The fake endpoint's folder and the test's own copy of the output (run.out) are left
# out: they are not part of the VPS.
fake_vps_snapshot() {
  find "$T" -path "$T/endpoint" -prune -o ! -path "$T/run.out" -printf '%p %s %T@\n' | sort
}

test_inventory_prints_each_fact_under_its_heading_and_changes_nothing() {
  app_working cms
  mkdir -p "$T/apps/stateless" "$T/apps/forgotten"
  touch "$T/apps/stateless/no-backup"
  run_at 2026-10-20T07:00:00Z
  # A docker that only says what it was asked, so the test needs no containers.
  mkdir -p "$T/runner/bin"
  printf '#!/usr/bin/env bash\necho "fake docker: $*"\n' > "$T/runner/bin/docker"
  chmod +x "$T/runner/bin/docker"

  local before out
  before="$(fake_vps_snapshot)"
  out="$(backups inventory)" || fail "inventory failed: $out" || return 1
  assert_eq "$(fake_vps_snapshot)" "$before" "the fake VPS after inventory" || return 1

  # Each heading, in this order.
  assert_eq "$(echo "$out" | grep '^## ' | tr '\n' '|')" \
    "## System|## Memory|## Disk|## Containers|## Images|## Volumes and their sizes|## Docker networks|## Apps and their backup files|## Backup runner|" \
    "headings" || return 1
  echo "$out" | grep -q "fake docker: ps -a" || fail "containers not listed: $out" || return 1
  echo "$out" | grep -q "fake docker: system df -v" || fail "volume sizes not listed: $out" || return 1
  echo "$out" | grep -Eq '^cms +backup.sh restore.sh$' || fail "cms's files: $out" || return 1
  echo "$out" | grep -Eq '^stateless +no-backup$' || fail "stateless's files: $out" || return 1
  echo "$out" | grep -Eq '^forgotten +none$' || fail "forgotten's files: $out" || return 1
  # The runner's last run, from its log.
  echo "$out" | grep -q "run as 2026-10-20T07:00:00Z" || fail "last run not shown: $out" || return 1
  echo "$out" | grep -Eq '^cms +backed up$' || fail "cms's last result: $out"
}

run_tests "$@"
