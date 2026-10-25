#!/usr/bin/env bash
# Tests for host/apply.sh. Each test builds a fake server root in a temp folder (an Ubuntu
# 26.04 sshd_config whose Include points inside it, a host key, and an admin with a key),
# runs apply.sh against it with HOST_ROOT, and checks the files written, what --check
# reports, and what was refused. Commands that need a real kernel, init or apt (systemctl,
# apt-get, swapon, docker, ...) are stubbed by stub.sh, which logs each call. sshd is the
# real one, so `sshd -t` really checks the config.
#
#   bash tests/host/test.sh            # every test
#   bash tests/host/test.sh check      # tests whose name contains "check"
#   KEEP_FAKE_ROOT=1 bash tests/host/test.sh   # keep each fake root to look at
#
# Needs sshd (openssh-server) and ssh-keygen.
set -uo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
here="$repo/tests/host"
# shellcheck source=tests/host/lib.sh
source "$here/lib.sh"

SSHD_DROPIN=/etc/ssh/sshd_config.d/00-indy-center.conf

# ---------------------------------------------------------------------------
# The fake server
# ---------------------------------------------------------------------------

setup() {
  T="$(mktemp -d)"
  R="$T/root"
  # A copy of host/, so a test can change a file in it without touching the repo's.
  cp -r "$repo/host" "$T/host"

  mkdir -p "$R/etc/ssh/sshd_config.d"
  ssh-keygen -q -t ed25519 -N '' -f "$R/etc/ssh/ssh_host_ed25519_key"
  # Ubuntu's own sshd_config starts with the Include; this one points it inside the fake root.
  cat > "$R/etc/ssh/sshd_config" <<EOF
Include $R/etc/ssh/sshd_config.d/*.conf
HostKey $R/etc/ssh/ssh_host_ed25519_key
KbdInteractiveAuthentication no
UsePAM yes
EOF
  printf 'NAME="Ubuntu"\nVERSION_ID="26.04"\nVERSION_CODENAME=resolute\n' > "$R/etc/os-release"
  echo "/dev/vda1 / ext4 defaults 0 1" > "$R/etc/fstab"
  admin_with_key hayden

  # chown too, since the test isn't root.
  make_stubs "$T/bin" "$here/stub.sh" chown
  export STUB_LOG="$T/calls" STUB_STATE="$T/state"
  : > "$STUB_LOG"
  # Ubuntu's image comes with a time service, installed but (in the fake) not started.
  mkdir -p "$STUB_STATE/installed"
  touch "$STUB_STATE/installed/systemd-timesyncd"
}

teardown() {
  if [ -n "${KEEP_FAKE_ROOT:-}" ]; then echo "    kept $T" >&3; else rm -rf "$T"; fi
}

# admin_with_key USER [OPTIONS]: USER has a real key in authorized_keys, with OPTIONS
# in front of it if given.
admin_with_key() {
  mkdir -p "$R/home/$1/.ssh"
  ssh-keygen -q -t ed25519 -N '' -C "$1@laptop" -f "$T/$1-key"
  echo "${2:+$2 }$(cat "$T/$1-key.pub")" > "$R/home/$1/.ssh/authorized_keys"
}

# Runs host/apply.sh (the test's copy) against the fake root, as admin hayden via sudo.
# Its output goes to $T/out, its exit code to $T/rc.
apply() {
  PATH="$T/bin:$PATH:/usr/sbin:/sbin" HOST_ROOT="$R" SUDO_USER="${ADMIN-hayden}" \
    bash "$T/host/apply.sh" "$@" > "$T/out" 2>&1
  echo $? > "$T/rc"
}

rc() { cat "$T/rc"; }

assert_file_has() { grep -qE -- "$2" "$R$1" 2>/dev/null || fail "$1 lacks /$2/"; }
assert_out_has() { grep -qE -- "$1" "$T/out" || fail "output lacks /$1/"; }
assert_out_lacks() { ! grep -qE -- "$1" "$T/out" || fail "output has: $(grep -E -- "$1" "$T/out" | head -1)"; }
assert_called() { grep -qxE -- "$1" "$STUB_LOG" || fail "never called: $1"; }
assert_not_called() { ! grep -qE -- "$1" "$STUB_LOG" || fail "called: $(grep -E -- "$1" "$STUB_LOG" | head -1)"; }

# Runs one test on a fresh fake server, showing apply.sh's last output if it fails.
run_one() {
  local rc=0
  setup
  ( set -e; "$1" ) || rc=1
  [ "$rc" = 0 ] || { echo "    last apply.sh output:"; sed 's/^/      /' "$T/out" 2>/dev/null | tail -20; }
  teardown
  return "$rc"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test_apply_on_an_empty_server_sets_up_everything_and_check_is_then_clean() {
  apply
  assert_eq "$(rc)" 0 "apply's exit code" || return 1

  # SSH: keys only, no root, no X11, only the admins and deploy.
  assert_file_has $SSHD_DROPIN '^PasswordAuthentication no$' || return 1
  assert_file_has $SSHD_DROPIN '^PermitRootLogin no$' || return 1
  assert_file_has $SSHD_DROPIN '^X11Forwarding no$' || return 1
  assert_file_has $SSHD_DROPIN '^AllowUsers .*\bdeploy\b' || return 1
  assert_file_has $SSHD_DROPIN '^AllowUsers .*\bhayden\b' || return 1

  # Docker from Docker's apt repository for this release, held, with live-restore and
  # the default log limit.
  assert_file_has /etc/apt/sources.list.d/docker.sources '^URIs: https://download.docker.com/linux/ubuntu$' || return 1
  assert_file_has /etc/apt/sources.list.d/docker.sources '^Suites: resolute$' || return 1
  assert_file_has /etc/apt/sources.list.d/docker.sources '^Signed-By: /etc/apt/keyrings/docker.asc$' || return 1
  assert_file_has /etc/apt/keyrings/docker.asc 'BEGIN PGP PUBLIC KEY BLOCK' || return 1
  assert_file_has /etc/docker/daemon.json '"live-restore": true' || return 1
  assert_file_has /etc/docker/daemon.json '"max-size": "10m"' || return 1
  assert_file_has /etc/docker/daemon.json '"max-file": "5"' || return 1
  assert_called "apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin" || return 1
  assert_called "apt-mark hold docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin" || return 1

  # Security updates only, never an automatic reboot.
  assert_file_has /etc/apt/apt.conf.d/20auto-upgrades 'Unattended-Upgrade "1"' || return 1
  assert_file_has /etc/apt/apt.conf.d/52unattended-upgrades-indy-center 'Automatic-Reboot "false"' || return 1
  assert_file_has /etc/apt/apt.conf.d/52unattended-upgrades-indy-center '-security";' || return 1
  ! grep -qE -- '-updates' "$R/etc/apt/apt.conf.d/52unattended-upgrades-indy-center" || fail "allows -updates" || return 1

  # journald capped and kept 30 days, swap, UTC.
  assert_file_has /etc/systemd/journald.conf.d/00-indy-center.conf '^SystemMaxUse=1G$' || return 1
  assert_file_has /etc/systemd/journald.conf.d/00-indy-center.conf '^MaxRetentionSec=30day$' || return 1
  assert_file_has /etc/sysctl.d/60-indy-center.conf '^vm.swappiness *= *10$' || return 1
  assert_file_has /etc/fstab '^/swapfile none swap sw 0 0$' || return 1
  assert_eq "$(stat -c %s "$R/swapfile")" 4294967296 "swapfile size" || return 1
  assert_eq "$(stat -c %a "$R/swapfile")" 600 "swapfile mode" || return 1
  assert_called "swapon $R/swapfile" || return 1
  assert_eq "$(readlink "$R/etc/localtime")" /usr/share/zoneinfo/Etc/UTC || return 1

  # The deploy user's folders, and the network every app joins.
  local d
  for d in traefik apps backup-runner backups; do
    [ -d "$R/home/deploy/$d" ] || fail "no /home/deploy/$d" || return 1
  done
  assert_called "chown deploy:deploy $R/home/deploy $R/home/deploy/traefik $R/home/deploy/apps $R/home/deploy/backup-runner $R/home/deploy/backups" || return 1
  assert_called "docker network create traefik-shared" || return 1

  # And now the server matches host/.
  apply --check
  assert_eq "$(rc)" 0 "--check's exit code" || return 1
  assert_out_has '^No differences from host/' || return 1
}

test_a_second_apply_changes_and_reloads_nothing() {
  apply
  local before
  before="$(snapshot "$R")"
  : > "$STUB_LOG"
  apply
  assert_eq "$(rc)" 0 || return 1
  assert_eq "$(snapshot "$R")" "$before" "files after the second run" || return 1
  assert_out_has '^Nothing to change' || return 1
  assert_not_called '^(systemctl (restart|enable|try)|apt-get|apt-mark hold|fallocate|mkswap|swapon /|sysctl|chown|docker network create)'
}

test_held_packages_count_as_installed() {
  apply
  [ -e "$STUB_STATE/held/docker-ce" ] || fail "docker-ce wasn't held" || return 1
  apply --check
  assert_eq "$(rc)" 0 "--check's exit code" || return 1
  assert_out_lacks '^differs  packages' || return 1
  : > "$STUB_LOG"
  apply
  assert_eq "$(rc)" 0 || return 1
  assert_not_called '^apt-get install'
}

test_check_names_a_changed_file_and_apply_puts_it_back_reloading_only_its_service() {
  apply
  sed -i 's/"max-file": "5"/"max-file": "50"/' "$R/etc/docker/daemon.json"
  : > "$STUB_LOG"

  apply --check
  assert_eq "$(rc)" 1 "--check's exit code" || return 1
  assert_out_has '^differs  /etc/docker/daemon.json' || return 1
  assert_out_has '^    \+    "max-file": "5"' || return 1
  assert_eq "$(grep -c '^differs' "$T/out")" 1 "differences reported" || return 1
  assert_out_has '^1 difference' || return 1
  assert_eq "$(grep -vE '^(dpkg-query|apt-mark showhold|swapon --show|systemctl is-active|timedatectl show|docker (info|network inspect))' "$STUB_LOG" || true)" "" \
    "--check only looks" || return 1

  apply
  assert_eq "$(rc)" 0 || return 1
  cmp -s "$repo/host/files/etc/docker/daemon.json" "$R/etc/docker/daemon.json" || fail "daemon.json not put back" || return 1
  assert_called "systemctl restart docker" || return 1
  assert_not_called '^systemctl (try-reload-or-restart ssh|restart systemd-journald)' || return 1

  apply --check
  assert_eq "$(rc)" 0 "--check after putting it back"
}

test_check_reports_everything_missing_on_an_empty_server() {
  apply --check
  assert_eq "$(rc)" 1 || return 1
  assert_out_has "^differs  $SSHD_DROPIN  \(missing\)" || return 1
  assert_out_has '^differs  packages .*docker-ce .*\(not installed\)' || return 1
  assert_out_has '^differs  /swapfile' || return 1
  assert_out_has '^differs  Docker network traefik-shared' || return 1
  [ ! -e "$R/etc/docker" ] || fail "--check wrote files"
}

test_check_runs_without_root_and_apply_does_not() {
  [ "$(id -u)" != 0 ] || { echo "    (running as root: nothing to show)"; return 0; }
  apply
  apply --check
  assert_eq "$(rc)" 0 "--check as $(id -un)" || return 1
  ! grep -qi 'permission denied' "$T/out" || fail "--check hit a permission error" || return 1

  # Without the fake root, a change to the real server needs root, and stops before any.
  : > "$STUB_LOG"
  PATH="$T/bin:$PATH" bash "$T/host/apply.sh" > "$T/out" 2>&1
  assert_eq "$?" 1 || return 1
  assert_out_has 'needs root' || return 1
  assert_eq "$(cat "$STUB_LOG")" "" "commands run"
}

test_check_that_cannot_finish_says_so_with_its_own_exit_code() {
  apply
  # A managed file's folder that can't be read: find fails partway through.
  chmod 000 "$T/host/files/etc/docker"
  apply --check
  chmod 755 "$T/host/files/etc/docker"
  assert_eq "$(rc)" 3 || return 1
  assert_out_has "couldn't finish"
}

test_check_without_access_to_home_deploy_reports_it_as_a_difference() {
  apply
  # The test runs as the folder's owner, so take its access away entirely.
  chmod 000 "$R/home/deploy"
  apply --check
  chmod 755 "$R/home/deploy"
  assert_eq "$(rc)" 1 || return 1
  assert_out_has "^differs  /home/deploy's folders  \(can't look inside"
}

test_check_with_docker_down_reports_the_network_as_a_difference() {
  apply
  touch "$STUB_STATE/docker-down"
  apply --check
  assert_eq "$(rc)" 1 || return 1
  assert_out_has "^differs  Docker network traefik-shared  \(can't reach Docker"
}

# --- The clock -----------------------------------------------------------------------------

test_a_stopped_timesyncd_is_started() {
  apply
  assert_called "systemctl enable --now systemd-timesyncd" || return 1
  rm "$STUB_STATE/active/systemd-timesyncd"
  apply --check
  assert_eq "$(rc)" 1 || return 1
  assert_out_has '^differs  systemd-timesyncd  \(installed, but not running\)'
}

test_chrony_is_kept_and_timesyncd_never_installed() {
  rm "$STUB_STATE/installed/systemd-timesyncd"
  mkdir -p "$STUB_STATE/active"
  touch "$STUB_STATE/installed/chrony" "$STUB_STATE/active/chrony"
  apply
  assert_eq "$(rc)" 0 || return 1
  assert_not_called 'timesyncd' || return 1
  apply --check
  assert_eq "$(rc)" 0
}

test_check_reports_a_clock_that_is_not_synchronised() {
  apply
  touch "$STUB_STATE/unsynchronised"
  apply --check
  assert_eq "$(rc)" 1 || return 1
  assert_out_has '^differs  clock  \(not synchronised \(systemd-timesyncd is running\)\)'
}

test_no_time_service_is_refused_not_installed() {
  rm "$STUB_STATE/installed/systemd-timesyncd"
  apply
  assert_eq "$(rc)" 1 || return 1
  assert_out_has '^refused  clock: no time service installed' || return 1
  assert_not_called '^apt-get install .*(timesyncd|chrony)'
}

# --- Swap ----------------------------------------------------------------------------------

test_an_existing_swapfile_line_in_fstab_is_not_added_twice() {
  echo "/swapfile swap swap defaults 0 0" >> "$R/etc/fstab"
  apply
  assert_eq "$(grep -c '^/swapfile' "$R/etc/fstab")" 1
}

test_a_swapfile_that_cannot_be_turned_off_is_left_alone() {
  truncate -s 2G "$R/swapfile"
  mkdir -p "$STUB_STATE" && echo "$R/swapfile" > "$STUB_STATE/swaps"
  touch "$STUB_STATE/swapoff-fails"
  apply
  assert_eq "$(rc)" 1 || return 1
  assert_out_has '^refused  /swapfile: ' || return 1
  assert_out_has 'after a reboot' || return 1
  assert_eq "$(stat -c %s "$R/swapfile")" 2147483648 "the old swapfile stays"
}

# --- Reloads -------------------------------------------------------------------------------

test_a_reload_that_fails_is_refused() {
  apply
  echo "vm.swappiness = 11" > "$T/host/files/etc/sysctl.d/60-indy-center.conf"
  touch "$STUB_STATE/sysctl-fails"
  apply
  assert_eq "$(rc)" 1 || return 1
  assert_out_has '^refused  the sysctl settings: its new config is in place, but sysctl' || return 1
  assert_out_lacks '^reloaded the sysctl'
}

# --- SSH guards ----------------------------------------------------------------------------

# Applies the good config, then changes host/'s copy with the sed expression given and
# applies again: the second run must refuse the drop-in and leave the good one in place.
assert_sshd_change_refused() {
  apply
  local good
  good="$(md5sum < "$R$SSHD_DROPIN")"
  sed -i "$1" "$T/host/files$SSHD_DROPIN"
  echo "vm.swappiness = 11" > "$T/host/files/etc/sysctl.d/60-indy-center.conf"
  : > "$STUB_LOG"
  apply
  assert_eq "$(rc)" 1 "apply's exit code" || return 1
  assert_out_has "^refused  $SSHD_DROPIN: $2" || return 1
  assert_eq "$(md5sum < "$R$SSHD_DROPIN")" "$good" "the old sshd config stays" || return 1
  assert_not_called '^systemctl try-reload-or-restart ssh' || return 1
  # Everything else is still applied.
  assert_file_has /etc/sysctl.d/60-indy-center.conf '= 11$'
}

test_an_sshd_config_that_fails_sshd_t_is_refused() {
  # shellcheck disable=SC2016 # a sed expression: append a line sshd doesn't know
  assert_sshd_change_refused '$a NotAnOption yes' 'sshd -t rejects it'
}

test_an_sshd_config_without_deploy_in_allowusers_is_refused() {
  assert_sshd_change_refused 's/^AllowUsers .*/AllowUsers hayden/' 'deploy is not in AllowUsers'
}

test_an_sshd_config_without_allowusers_is_refused() {
  assert_sshd_change_refused '/^AllowUsers/d' 'deploy is not in AllowUsers'
}

test_password_login_is_not_turned_off_unless_the_admin_running_it_has_a_key() {
  rm "$R/home/hayden/.ssh/authorized_keys"
  apply
  assert_eq "$(rc)" 1 || return 1
  assert_out_has "^refused  $SSHD_DROPIN: hayden, who is running this, has no SSH key" || return 1
  [ ! -e "$R$SSHD_DROPIN" ] || fail "the drop-in was installed" || return 1
  # The rest of the server is still set up.
  assert_file_has /etc/docker/daemon.json live-restore
}

test_an_admin_key_line_with_options_counts_as_a_key() {
  admin_with_key hayden 'from="192.0.2.1"'
  apply
  assert_eq "$(rc)" 0 || return 1
  [ -e "$R$SSHD_DROPIN" ] || fail "the drop-in wasn't installed"
}

test_the_admin_running_it_must_be_in_allowusers() {
  admin_with_key steve
  ADMIN=steve apply
  assert_eq "$(rc)" 1 || return 1
  assert_out_has "^refused  $SSHD_DROPIN: steve, who is running this, is not in its AllowUsers" || return 1
  [ ! -e "$R$SSHD_DROPIN" ] || fail "the drop-in was installed"
}

test_sshd_changes_need_to_know_which_admin_is_running_it() {
  ADMIN='' apply
  assert_eq "$(rc)" 1 || return 1
  assert_out_has "^refused  $SSHD_DROPIN: can't tell which admin is running this" || return 1
  [ ! -e "$R$SSHD_DROPIN" ] || fail "the drop-in was installed"
}

test_a_good_sshd_change_is_applied_and_ssh_reloaded() {
  apply
  assert_called "systemctl try-reload-or-restart ssh" || return 1
  sed -i 's/^AllowUsers .*/AllowUsers hayden steve deploy/' "$T/host/files$SSHD_DROPIN"
  : > "$STUB_LOG"
  apply
  assert_eq "$(rc)" 0 || return 1
  assert_file_has "$SSHD_DROPIN" '^AllowUsers hayden steve deploy$' || return 1
  assert_called "systemctl try-reload-or-restart ssh"
}

test_check_lists_sshd_drop_ins_it_does_not_manage_without_counting_them() {
  # As on ALEXANDRIA: cloud-init's turns password login on, the image's own turns it off.
  printf 'PasswordAuthentication yes\nPermitRootLogin yes\n' > "$R/etc/ssh/sshd_config.d/50-cloud-init.conf"
  echo "PasswordAuthentication no" > "$R/etc/ssh/sshd_config.d/60-cloudimg-settings.conf"
  apply
  assert_eq "$(rc)" 0 || return 1
  apply --check
  assert_eq "$(rc)" 0 "they aren't differences" || return 1
  assert_out_has '^extra    /etc/ssh/sshd_config.d/50-cloud-init.conf  \(not in host/; sets PasswordAuthentication yes, PermitRootLogin yes, which ours overrides\)$' || return 1
  assert_out_has '^extra    /etc/ssh/sshd_config.d/60-cloudimg-settings.conf  \(not in host/\)$' || return 1
  assert_out_lacks "^extra    $SSHD_DROPIN"
}

# --- sudoers -------------------------------------------------------------------------------

test_check_lists_sudoers_files_apart_from_readme() {
  mkdir -p "$R/etc/sudoers.d"
  echo "# sudo's own README" > "$R/etc/sudoers.d/README"
  echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > "$R/etc/sudoers.d/90-cloud-init-users"
  apply
  apply --check
  assert_eq "$(rc)" 0 "they aren't differences" || return 1
  assert_out_has '^extra    /etc/sudoers.d/90-cloud-init-users  \(not in host/; it can grant sudo\)$' || return 1
  assert_out_lacks 'sudoers.d/README'
}

test_check_says_when_it_cannot_list_sudoers() {
  mkdir -p "$R/etc/sudoers.d"
  chmod 000 "$R/etc/sudoers.d"
  apply --check
  chmod 755 "$R/etc/sudoers.d"
  assert_out_has "^extra    /etc/sudoers.d/  \(can't list it"
}

# ---------------------------------------------------------------------------

run_tests "$@"
