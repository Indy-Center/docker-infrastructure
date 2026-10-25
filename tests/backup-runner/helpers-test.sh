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

# Runs a helper command in its own process group, waits until its output shows the given
# text, then hangs up on the whole group, as a dropped SSH session does. Its output is in
# $T/hup.out.
# Temp files go to $T/tmp, so a test can see what was left there.
#   hang_up_at <text> <command> <args…>
hang_up_at() {
  local text="$1"
  shift
  mkdir -p "$T/tmp"
  env $(fake_vps_env) TMPDIR="$T/tmp" setsid bash "$repo/backup-runner/backups.sh" "$@" \
    > "$T/hup.out" 2>&1 < /dev/null &
  local pid=$! i
  for i in $(seq 100); do grep -q "$text" "$T/hup.out" && break; sleep 0.1; done
  grep -q "$text" "$T/hup.out" || fail "never got to \"$text\": $(cat "$T/hup.out")" || return 1
  # A moment for what it started to get going.
  sleep 0.5
  kill -HUP -- "-$pid"
  wait "$pid"
  return 0
}

# An age that writes part of its output, then hangs, as a slow decrypt would.
age_that_hangs() {
  mkdir -p "$T/runner/bin"
  cat > "$T/runner/bin/age" <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do [ "$1" = -o ] && echo "half of the data" > "$2"; shift; done
sleep 30
EOF
  chmod +x "$T/runner/bin/age"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test_every_command_has_help_and_runs_nothing_for_it() {
  local cmd out out_cmd
  out="$(backups --help)" || fail "backups --help failed" || return 1
  for cmd in now list fetch restore scratch-cms restore-check media-find media-get inventory; do
    echo "$out" | grep -q "backups $cmd" || fail "backups --help leaves out $cmd: $out" || return 1
    out_cmd="$(backups "$cmd" --help)" || fail "backups $cmd --help failed: $out_cmd" || return 1
    echo "$out_cmd" | head -n 1 | grep -q "^backups $cmd" || fail "$cmd's help: $out_cmd" || return 1
  done
  # Help never runs the command: no log was started.
  [ ! -e "$T/runner/logs" ] || fail "a --help started the log"
}

test_a_command_missing_its_arguments_shows_its_help() {
  local out
  out="$(backups fetch)" && fail "fetch with no arguments should fail" && return 1
  echo "$out" | grep -q "^backups fetch <app> <backup>" || fail "unexpected output: $out"
}

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

test_a_bucket_that_cant_be_listed_says_so_rather_than_finding_nothing() {
  app_working cms
  run_at 2026-10-20T07:00:00Z
  # As a bad R2 key or a broken rclone.conf would.
  printf '[r2]\ntype = nosuchbackend\n' > "$T/runner/secrets/rclone.conf"
  local cmd out
  for cmd in "list cms" "fetch cms latest $T" "media-find plane" "media-get payload-media/plane.png $T"; do
    out="$(backups $cmd)" && fail "$cmd should fail: $out" && return 1
    echo "$out" | grep -q "Couldn't list" || fail "$cmd: $out" || return 1
    echo "$out" | grep -q "nosuchbackend" || fail "$cmd does not show rclone's error: $out" || return 1
    echo "$out" | grep -qi "no backups\|no file" && fail "$cmd blames the name: $out" && return 1
  done
  return 0
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

test_fetch_hung_up_while_decrypting_leaves_nothing_behind() {
  app_working cms
  run_at 2026-10-20T07:00:00Z
  age_that_hangs
  mkdir "$T/out"
  hang_up_at Downloading fetch cms latest "$T/out" || return 1
  sleep 0.5
  assert_eq "$(ls -A "$T/out")" "" "left in the folder" || return 1
  assert_eq "$(ls -A "$T/tmp")" "" "left in temp"
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

test_now_hung_up_during_the_recipe_leaves_no_unencrypted_copy() {
  mkdir -p "$T/apps/cms"
  printf 'echo "data of cms" > "$1/cms.txt"\nsleep 30\n' > "$T/apps/cms/backup.sh"
  hang_up_at "running backup.sh" now cms || return 1
  sleep 0.5
  assert_eq "$(ls -A "$T/staging")" "" "left in staging"
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

test_restore_waiting_at_its_question_does_not_hold_up_the_hourly_run() {
  app_restorable cms
  run_at 2026-10-20T07:00:00Z
  # A restore left at its question: its input is a pipe nobody has written to yet.
  mkfifo "$T/answer"
  env $(fake_vps_env) bash "$repo/backup-runner/backups.sh" restore cms latest \
    < "$T/answer" > "$T/restore.out" 2>&1 &
  local pid=$!
  exec 7> "$T/answer"
  local i
  for i in $(seq 100); do grep -q "Type the app's name" "$T/restore.out" && break; sleep 0.1; done
  grep -q "Type the app's name" "$T/restore.out" || fail "restore never asked: $(cat "$T/restore.out")" || return 1

  run_at 2026-10-21T07:00:00Z
  echo cms >&7
  exec 7>&-
  wait "$pid" || fail "restore failed: $(cat "$T/restore.out")" || return 1
  assert_count daily/cms 2 || return 1
  grep -q "skipped: the previous run is still running" "$T/runner/logs/runner.log" \
    && fail "the hourly run stepped aside for a restore that was only asking" && return 1
  assert_eq "$(cat "$T/restore-got")" "data of cms"
}

test_restore_whose_script_leaves_something_running_does_not_hold_up_the_hourly_run() {
  app_restorable cms
  run_at 2026-10-20T07:00:00Z
  # Something restore.sh started is still running, with its output, after restore.sh ends.
  echo 'sleep 5 &' >> "$T/apps/cms/restore.sh"
  echo cms | env $(fake_vps_env) bash "$repo/backup-runner/backups.sh" restore cms latest \
    > "$T/restore.out" 2>&1 || fail "restore failed: $(cat "$T/restore.out")" || return 1
  run_at 2026-10-21T07:00:00Z
  grep -q "skipped: the previous run is still running" "$T/runner/logs/runner.log" \
    && fail "the hourly run stepped aside after the restore had finished" && return 1
  assert_count daily/cms 2
}

test_restore_hung_up_at_its_question_leaves_nothing_behind() {
  app_restorable cms
  run_at 2026-10-20T07:00:00Z
  # Its input stays open and silent, as a person who walked away.
  mkfifo "$T/answer"
  exec 7<> "$T/answer"
  env $(fake_vps_env) setsid bash "$repo/backup-runner/backups.sh" restore cms latest \
    < "$T/answer" > "$T/hup.out" 2>&1 &
  local pid=$! i
  for i in $(seq 100); do grep -q "Type the app's name" "$T/hup.out" && break; sleep 0.1; done
  kill -HUP -- "-$pid"
  wait "$pid"
  exec 7>&-
  sleep 0.5
  assert_eq "$(ls -A "$T/staging")" "" "left in staging" || return 1
  [ ! -e "$T/restore-got" ] || fail "restore.sh ran"
}

test_restore_and_now_run_the_apps_scripts_with_the_usual_umask() {
  # The helpers keep what they write to themselves, but an app's own scripts get the
  # umask they would get anywhere else, so files they make stay readable as usual.
  app_working cms
  echo "umask > \"$T/restore-umask\"" > "$T/apps/cms/restore.sh"
  echo "umask > \"$T/backup-umask\"; echo data > \"\$1/cms.txt\"" > "$T/apps/cms/backup.sh"
  umask 022
  backups now cms > /dev/null || fail "now failed" || return 1
  echo cms | backups restore cms latest > /dev/null || fail "restore failed" || return 1
  assert_eq "$(cat "$T/backup-umask")" 0022 "backup.sh's umask" || return 1
  assert_eq "$(cat "$T/restore-umask")" 0022 "restore.sh's umask"
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
  echo "$out" | grep -q "payload-media.*courses/Plane.png" || fail "no put-back instructions: $out" || return 1
  # And how to get it to your computer: a copy in /tmp that your own login can read.
  echo "$out" | grep -qF "install -m 644 '$T/out/Plane.png' '/tmp/Plane.png'" \
    || fail "no copy to /tmp: $out"
}

test_media_get_into_tmp_says_to_make_the_file_readable_not_copy_it() {
  # The file goes into the real /tmp, as on the VPS, under a name no one else uses.
  local name="media-get-test-$$-$RANDOM.png"
  media_bucket payload-media
  echo "plane" > "$T/r2/payload-media/$name"
  run_at 2026-10-20T07:00:00Z

  local out status
  out="$(backups media-get "payload-media/$name" /tmp)"
  status=$?
  rm -f "/tmp/$name"
  [ "$status" = 0 ] || fail "media-get failed: $out" || return 1
  # Copying a file in /tmp onto itself fails, so it says to make that file readable.
  echo "$out" | grep -qF "chmod 644 '/tmp/$name'" || fail "no chmod: $out" || return 1
  echo "$out" | grep -q "install -m" && fail "copies the file onto itself: $out" && return 1
  return 0
}

test_media_get_without_a_bucket_and_path_says_what_it_needs() {
  local arg out
  for arg in payload-media payload-media/ plane.png; do
    out="$(backups media-get "$arg" "$T")" && fail "media-get $arg should fail: $out" && return 1
    echo "$out" | grep -q "<bucket>/<path>" || fail "media-get $arg: $out" || return 1
  done
  return 0
}

test_media_get_of_a_file_not_in_the_copy_says_so() {
  local out
  out="$(backups media-get payload-media/nothing.png "$T")" && fail "media-get should fail: $out" && return 1
  echo "$out" | grep -q "No file media/payload-media/nothing.png" || fail "unexpected output: $out"
}

# The scratch CMS tests' container name and port, and their fake CMS backups, are in
# fake-vps.sh.

# Runs SQL in the scratch database and prints the result, one row per line.
scratch_sql() { docker exec "$BACKUP_SCRATCH_CONTAINER" psql -U postgres -tAc "$1" payload; }

test_scratch_cms_loads_the_cms_recipes_tar_and_is_removed_on_request() {
  have_docker || return 0
  remove_test_containers_on_exit
  # What payload's recipe writes: payload.tar, holding payload.dump and row-counts.tsv.
  cms_backup_with_counts 'pages\t1\n'
  run_at 2026-10-20T07:00:00Z

  local out
  out="$(backups scratch-cms latest)" || fail "scratch-cms failed: $out" || return 1
  assert_eq "$(scratch_sql 'select slug from pages')" "sops" || return 1
  echo "$out" | grep -q "docker exec -it $BACKUP_SCRATCH_CONTAINER psql" || fail "no way to connect: $out" || return 1
  echo "$out" | grep -q "127.0.0.1:25432" || fail "no port to connect on: $out" || return 1
  assert_eq "$(ls -A "$T/staging")" "" "decrypted backup left behind" || return 1

  # Only one at a time.
  out="$(backups scratch-cms latest)" && fail "a second scratch-cms should stop: $out" && return 1
  echo "$out" | grep -q "already" || fail "unexpected output: $out" || return 1

  backups scratch-cms remove > /dev/null || fail "remove failed" || return 1
  ! container_exists "$BACKUP_SCRATCH_CONTAINER" || fail "the container is still there"
}

test_scratch_cms_loads_a_bare_custom_format_dump() {
  have_docker || return 0
  remove_test_containers_on_exit
  make_cms_dump "$T/payload.dump"
  cms_backing_up "$T/payload.dump"
  run_at 2026-10-20T07:00:00Z
  backups scratch-cms latest > /dev/null || fail "scratch-cms failed" || return 1
  assert_eq "$(scratch_sql 'select slug from pages')" "sops"
}

test_scratch_cms_that_fails_to_load_says_so_and_is_not_ready() {
  have_docker || return 0
  remove_test_containers_on_exit
  # Starts like a custom-format dump, but isn't one.
  printf 'PGDMP and then nothing pg_restore can read' > "$T/payload.dump"
  cms_backing_up "$T/payload.dump"
  run_at 2026-10-20T07:00:00Z
  local out
  out="$(backups scratch-cms latest)" && fail "scratch-cms should fail: $out" && return 1
  echo "$out" | grep -q "Loading failed" || fail "unexpected output: $out" || return 1
  echo "$out" | grep -q "is ready" && fail "it says it is ready: $out" && return 1
  echo "$out" | grep -q "backups scratch-cms remove" || fail "no way to remove it: $out"
}

test_scratch_cms_of_a_backup_with_no_dump_says_so() {
  have_docker || return 0
  remove_test_containers_on_exit
  mkdir "$T/pack"
  echo "notes" > "$T/pack/my notes.txt"
  tar -cf "$T/payload.tar" -C "$T/pack" "my notes.txt"
  cms_backing_up "$T/payload.tar"
  run_at 2026-10-20T07:00:00Z
  local out
  out="$(backups scratch-cms latest)" && fail "scratch-cms should fail: $out" && return 1
  echo "$out" | grep -q "no pg_dump custom-format dump" || fail "unexpected output: $out" || return 1
  ! container_exists "$BACKUP_SCRATCH_CONTAINER" || fail "it started a container anyway"
}

# --- The restore check ---------------------------------------------------------------
# Its fake CMS backups and container helpers are in fake-vps.sh, shared with test.sh.

test_restore_check_passes_on_a_good_backup_and_removes_its_container() {
  have_docker || return 0
  remove_test_containers_on_exit
  cms_backup_with_counts 'pages\t1\n'
  run_at 2026-10-20T07:00:00Z
  local out
  out="$(backups restore-check)" || fail "restore-check failed: $out" || return 1
  echo "$out" | grep -q "passed" || fail "unexpected output: $out" || return 1
  echo "$out" | grep -q "2026-10-20T070000Z-payload.tar.age" || fail "does not name the backup: $out" || return 1
  ! container_exists "$BACKUP_RESTORE_CHECK_CONTAINER" || fail "the container is still there" || return 1
  assert_eq "$(ls -A "$T/staging")" "" "decrypted backup left behind"
}

# Runs the restore check, which must fail with the given text in its output, and leave
# neither its container nor the decrypted backup behind.
check_fails_with() {
  local out
  out="$(backups restore-check)" && fail "restore-check should fail: $out" && return 1
  echo "$out" | grep -qF -- "$1" || fail "expected \"$1\" in: $out" || return 1
  ! container_exists "$BACKUP_RESTORE_CHECK_CONTAINER" || fail "the container is still there" || return 1
  assert_eq "$(ls -A "$T/staging" 2>/dev/null)" "" "decrypted backup left behind"
}

test_restore_check_fails_on_a_dump_missing_a_table() {
  have_docker || return 0
  remove_test_containers_on_exit
  cms_backup_with_counts 'pages\t1\nusers\t3\n'
  run_at 2026-10-20T07:00:00Z
  check_fails_with "Failed at check tables: table users is missing"
}

test_restore_check_fails_when_a_table_has_fewer_rows_than_counted() {
  have_docker || return 0
  remove_test_containers_on_exit
  cms_backup_with_counts 'pages\t5\n'
  run_at 2026-10-20T07:00:00Z
  check_fails_with "Failed at check tables: table pages holds only 1 of the 5 rows the backup counted"
}

test_restore_check_fails_on_a_corrupt_dump() {
  have_docker || return 0
  remove_test_containers_on_exit
  printf 'PGDMP and then nothing pg_restore can read' > "$T/corrupt.dump"
  cms_backup_of "$T/corrupt.dump" 'pages\t1\n'
  run_at 2026-10-20T07:00:00Z
  check_fails_with "Failed at load: pg_restore exited"
}

test_restore_check_fails_on_a_corrupt_backup_file() {
  app_working payload
  run_at 2026-10-20T07:00:00Z
  echo "not an age file" > "$T/r2/indy-center-backups/daily/payload/2026-10-20T070000Z-payload.txt.age"
  check_fails_with "Failed at download and decrypt: Decrypting failed"
}

test_restore_check_run_by_hand_waits_for_the_hourly_run() {
  app_working payload
  run_at 2026-10-20T07:00:00Z
  # An hourly run holds the lock for a moment; its own Sunday check uses the same container.
  flock "$T/runner/logs/run.lock" sleep 2 &
  sleep 0.5
  local out
  out="$(backups restore-check)"
  wait
  echo "$out" | grep -q "waiting for it to finish" || fail "it did not wait: $out"
}

test_restore_check_fails_with_no_backup() {
  check_fails_with "Failed at download and decrypt: No backups of payload"
}

test_restore_check_fails_on_a_backup_without_row_counts() {
  have_docker || return 0
  remove_test_containers_on_exit
  make_cms_dump "$T/payload.dump"
  cms_backing_up "$T/payload.dump"
  run_at 2026-10-20T07:00:00Z
  check_fails_with "Failed at unpack: 2026-10-20T070000Z-payload.dump.age has no row-counts.tsv"
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
