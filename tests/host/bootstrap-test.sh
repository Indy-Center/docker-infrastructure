#!/usr/bin/env bash
# Tests for host/bootstrap.sh, run as root in a fresh ubuntu:26.04 container with
# openssh-server installed, so users, groups, keys and sshd's own check are real. What
# needs a real init or apt (systemctl, apt-get, swapon, docker, ...) is stubbed by stub.sh,
# as in test.sh. Each test gets its own container.
#
#   bash tests/host/bootstrap-test.sh            # every test
#   bash tests/host/bootstrap-test.sh twice      # tests whose name contains "twice"
#
# Needs Docker. Without it the tests pass without running, except in CI.
set -uo pipefail

# BASH_SOURCE, not $0: inside the container this file is sourced.
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/host/lib.sh
source "$repo/tests/host/lib.sh"
IMAGE=host-bootstrap-test

build_image() {
  if ! docker info > /dev/null 2>&1; then
    [ "${CI:-}" = true ] && { echo "FAIL: no Docker, and in CI these tests must run"; exit 1; }
    echo "skipped: no Docker"
    exit 0
  fi
  docker build -q -t "$IMAGE" - > /dev/null <<'EOF' || exit 1
FROM ubuntu:26.04
RUN apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends openssh-server sudo && mkdir -p /run/sshd
EOF
}

# Runs one test in a new container, where this file is sourced with `inside`.
run_one() {
  docker run --rm -v "$repo:/repo:ro" -e TEST="$1" "$IMAGE" \
    bash -c 'source /repo/tests/host/bootstrap-test.sh inside'
}

# ---------------------------------------------------------------------------
# Inside the container
# ---------------------------------------------------------------------------

inside_setup() {
  cp -r /repo/host /root/host
  ssh-keygen -q -t ed25519 -N '' -C hayden@laptop -f /admin-key
  ssh-keygen -q -t ed25519 -N '' -C deploy@alexandria -f /deploy-key
  ADMIN_KEY="$(cat /admin-key.pub)" DEPLOY_KEY="$(cat /deploy-key.pub)"
  make_stubs /stubs /repo/tests/host/stub.sh
  export PATH="/stubs:$PATH" STUB_LOG=/calls STUB_STATE=/stub-state
  : > /calls
  # The image's time service (the container has none of its own).
  mkdir -p /stub-state/installed && touch /stub-state/installed/systemd-timesyncd
}

# Runs bootstrap.sh for hayden, typing a password (twice) when asked.
bootstrap() {
  local rc=0
  printf 'S3cret-pass\nS3cret-pass\n' |
    bash /root/host/bootstrap.sh alexandria hayden "$ADMIN_KEY" "$DEPLOY_KEY" > /out 2>&1 || rc=$?
  echo $rc > /rc
}

groups_of() { id -nG "$1" | tr ' ' '\n' | sort | tr '\n' ' '; }

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test_bootstrap_creates_the_admin_and_deploy() {
  bootstrap
  assert_eq "$(cat /rc)" 0 "bootstrap's exit code" || return 1

  # The admin: in sudo with a password, never in docker, logging in with their key.
  assert_eq "$(groups_of hayden)" "hayden sudo " "hayden's groups" || return 1
  assert_eq "$(passwd -S hayden | awk '{print $2}')" P "hayden has a password" || return 1
  assert_eq "$(cat /home/hayden/.ssh/authorized_keys)" "$ADMIN_KEY" || return 1
  assert_eq "$(stat -c '%U %a' /home/hayden/.ssh /home/hayden/.ssh/authorized_keys | tr '\n' ' ')" \
    "hayden 700 hayden 600 " || return 1

  # deploy: in docker, no password, its key line restricted.
  assert_eq "$(groups_of deploy)" "deploy docker " "deploy's groups" || return 1
  assert_eq "$(passwd -S deploy | awk '{print $2}')" L "deploy's password is locked" || return 1
  assert_eq "$(cat /home/deploy/.ssh/authorized_keys)" "restrict $DEPLOY_KEY" || return 1
  assert_eq "$(stat -c '%U %a' /home/deploy/.ssh /home/deploy/.ssh/authorized_keys | tr '\n' ' ')" \
    "deploy 700 deploy 600 " || return 1

  # The hostname, the base setup, and the reminder to check a second login.
  assert_eq "$(cat /etc/hostname)" alexandria || return 1
  [ -f /etc/ssh/sshd_config.d/00-indy-center.conf ] || fail "apply.sh didn't run" || return 1
  grep -qx 'Suites: resolute' /etc/apt/sources.list.d/docker.sources || fail "Docker's source isn't for 26.04" || return 1
  sshd -t || fail "sshd -t fails afterwards" || return 1
  grep -q 'second terminal' /out || fail "no reminder to test a second login"
}

test_bootstrap_upgrades_the_image_before_installing_anything() {
  bootstrap
  assert_eq "$(cat /rc)" 0 || return 1
  assert_eq "$(grep -m2 '^apt-get' /calls | awk '{print $2 " " $NF}' | tr '\n' ' ')" "update -q -y upgrade " \
    "the first apt-get calls" || return 1
  local upgrade install
  upgrade="$(grep -n '^apt-get .*upgrade$' /calls | head -1 | cut -d: -f1)"
  install="$(grep -n '^apt-get install' /calls | head -1 | cut -d: -f1)"
  [ "$upgrade" -lt "$install" ] || fail "installed before upgrading: $(cat /calls)"
}

test_bootstrap_removes_the_interim_sshd_drop_in() {
  printf 'PasswordAuthentication no\nPermitRootLogin prohibit-password\n' > /etc/ssh/sshd_config.d/01-interim.conf
  bootstrap
  assert_eq "$(cat /rc)" 0 || return 1
  [ ! -e /etc/ssh/sshd_config.d/01-interim.conf ] || fail "the interim drop-in is still there" || return 1
  grep -q 'removed /etc/ssh/sshd_config.d/01-interim.conf' /out || fail "it didn't say so" || return 1
  [ "$(grep -c '^systemctl try-reload-or-restart ssh$' /calls)" = 2 ] || fail "ssh wasn't reloaded after removing it: $(cat /calls)"
}

test_bootstrap_removes_cloud_inits_sudoers_file() {
  printf '# Created by cloud-init\nubuntu ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/90-cloud-init-users
  chmod 440 /etc/sudoers.d/90-cloud-init-users
  bootstrap
  assert_eq "$(cat /rc)" 0 || return 1
  [ ! -e /etc/sudoers.d/90-cloud-init-users ] || fail "cloud-init's sudoers file is still there" || return 1
  grep -q 'removed /etc/sudoers.d/90-cloud-init-users' /out || fail "it didn't say so" || return 1
  [ -e /etc/sudoers.d/README ] || fail "sudo's README went too" || return 1
  visudo -c -q || fail "visudo -c fails afterwards"
}

test_a_broken_sudoers_is_caught_by_visudo() {
  printf 'ubuntu ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/90-cloud-init-users
  echo "this is not sudoers syntax" > /etc/sudoers.d/50-broken
  chmod 440 /etc/sudoers.d/90-cloud-init-users /etc/sudoers.d/50-broken
  bootstrap
  assert_eq "$(cat /rc)" 1 || return 1
  grep -q 'visudo -c fails' /out || fail "no reason given" || return 1
  ! grep -q '^apt-get install' /calls || fail "it carried on to apply.sh"
}

test_bootstrap_run_twice_changes_nothing() {
  bootstrap
  assert_eq "$(cat /rc)" 0 || return 1
  local before
  before="$(snapshot /etc /home)"
  : > /calls
  # A second run never asks for the password again: nothing is typed this time.
  local rc=0
  bash /root/host/bootstrap.sh alexandria hayden "$ADMIN_KEY" "$DEPLOY_KEY" < /dev/null > /out 2>&1 || rc=$?
  assert_eq "$rc" 0 "second run's exit code" || return 1
  assert_eq "$(snapshot /etc /home)" "$before" "/etc and /home after the second run" || return 1
  # Only the upgrade, which finds nothing new.
  ! grep -qE '^(systemctl (restart|enable|try)|apt-get install|apt-mark hold|fallocate|swapon /|docker network create)' /calls ||
    fail "the second run changed something: $(cat /calls)"
}

test_deploys_key_line_gets_restrict_alone() {
  useradd -m -U deploy
  mkdir -p /home/deploy/.ssh
  echo "no-pty,no-port-forwarding,restrict $DEPLOY_KEY" > /home/deploy/.ssh/authorized_keys
  bootstrap
  assert_eq "$(cat /rc)" 0 || return 1
  assert_eq "$(cat /home/deploy/.ssh/authorized_keys)" "restrict $DEPLOY_KEY"
}

test_an_admin_not_in_allowusers_is_refused_before_anything_changes() {
  local rc=0
  printf 'pw\npw\n' | bash /root/host/bootstrap.sh alexandria steve "$ADMIN_KEY" "$DEPLOY_KEY" > /out 2>&1 || rc=$?
  assert_eq "$rc" 1 || return 1
  grep -q 'steve is not in AllowUsers' /out || fail "no reason given" || return 1
  ! id steve 2> /dev/null || fail "steve was created" || return 1
  ! id deploy 2> /dev/null || fail "deploy was created" || return 1
  ! grep -q '^apt-get' /calls || fail "apt-get ran"
}

test_a_bad_key_is_refused_before_anything_changes() {
  local rc=0
  bash /root/host/bootstrap.sh alexandria hayden "not a key" "$DEPLOY_KEY" < /dev/null > /out 2>&1 || rc=$?
  assert_eq "$rc" 1 || return 1
  grep -q "isn't an SSH public key" /out || fail "no reason given" || return 1
  ! id hayden 2> /dev/null || fail "hayden was created"
}

# ---------------------------------------------------------------------------

if [ "${1:-}" = inside ]; then
  set -uo pipefail
  inside_setup
  ( set -e; "$TEST" ) || { echo "    bootstrap.sh's output:"; sed 's/^/      /' /out 2> /dev/null; exit 1; }
  exit 0
fi
build_image
run_tests "$@"
