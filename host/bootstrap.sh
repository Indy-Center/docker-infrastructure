#!/usr/bin/env bash
# Turns a fresh Ubuntu 26.04 server into one docker-infrastructure can deploy to. Run it
# once, as root, at the first login (host/README.md, "First login"):
#
#   bash bootstrap.sh <hostname> <admin> '<admin's public key>' '<deploy's public key>'
#   bash bootstrap.sh alexandria hayden "$(cat hayden.pub)" "$(cat deploy.pub)"
#
# It upgrades the image's packages, creates the first admin (in sudo, with a password it
# asks for) and deploy (whose key line gets `restrict`), sets the hostname, runs apply.sh
# for everything else, then adds deploy to the docker group and removes the interim sshd
# drop-in from before it ran. It also removes cloud-init's sudoers file, checking the
# rest with visudo -c. It is safe to run again: what is already right is left
# alone. The admin must already be in AllowUsers in host/'s sshd drop-in.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# What an admin set by hand at first login to close password login until this ran.
INTERIM_DROPIN=/etc/ssh/sshd_config.d/01-interim.conf
# cloud-init's grant of passwordless sudo to an `ubuntu` user the image doesn't have. It
# does nothing today, but would give root to any `ubuntu` account made later.
CLOUD_INIT_SUDOERS=/etc/sudoers.d/90-cloud-init-users

die() {
  echo "bootstrap.sh: $*" >&2
  exit 1
}

if [ $# != 4 ] || [ "${1:-}" = -h ] || [ "${1:-}" = --help ]; then
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
  [ $# = 4 ] || exit 2
  exit 0
fi
hostname="$1" admin="$2" admin_key="$3" deploy_key="$4"

# ---------------------------------------------------------------------------
# Check everything before changing anything
# ---------------------------------------------------------------------------

[ "$(id -u)" = 0 ] || die "run it as root"
[[ $hostname =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "'$hostname' isn't a hostname (lower case letters, digits and -)"
[[ $admin =~ ^[a-z][a-z0-9-]*$ ]] || die "'$admin' isn't a username (lower case letters, digits and -)"
case "$admin" in root | deploy) die "the admin needs their own account, not $admin" ;; esac

# A key is one line, starting with its type: no options, which bootstrap.sh adds itself.
check_key() {
  local who="$1" key="$2"
  if ! [[ $key =~ ^(ssh-|ecdsa-|sk-)[^[:space:]]+[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$ ]] ||
    [ "$(wc -l <<< "$key")" != 1 ] ||
    ! ssh-keygen -l -f /dev/stdin <<< "$key" > /dev/null 2>&1; then
    die "$who's key isn't an SSH public key line (ssh-ed25519 AAAA... comment)"
  fi
}
check_key "$admin" "$admin_key"
check_key deploy "$deploy_key"

allowed="$(awk 'tolower($1) == "allowusers" { for (i = 2; i <= NF; i++) print $i }' "$here"/files/etc/ssh/sshd_config.d/*.conf)"
grep -qxF "$admin" <<< "$allowed" ||
  die "$admin is not in AllowUsers in host/'s sshd drop-in (files/etc/ssh/sshd_config.d/), so they couldn't log in afterwards. Add them there (in the repo) first."

# ---------------------------------------------------------------------------
# The image's packages, whose lists may be weeks old
# ---------------------------------------------------------------------------

echo "Upgrading the image's packages:"
export DEBIAN_FRONTEND=noninteractive
if ! apt-get update -q ||
  ! apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade; then
  die "apt-get couldn't upgrade the image's packages"
fi

# ---------------------------------------------------------------------------
# Users and keys
# ---------------------------------------------------------------------------

ensure_user() {
  id "$1" > /dev/null 2>&1 && return
  useradd --create-home --user-group --shell /bin/bash "$1" || die "couldn't create $1"
  echo "created user $1"
}

# ensure_key USER LINE: LINE is in USER's authorized_keys, replacing any other line for
# the same key (so its options are exactly LINE's). Other keys are left alone.
ensure_key() {
  local user="$1" line="$2" home dir file body
  home="$(getent passwd "$user" | cut -d: -f6)"
  dir="$home/.ssh"
  file="$dir/authorized_keys"
  install -d -m 700 -o "$user" -g "$user" "$dir"
  [ -e "$file" ] || install -m 600 -o "$user" -g "$user" /dev/null "$file"
  if ! grep -qxF "$line" "$file"; then
    body="$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^AAAA/) { print $i; exit } }' <<< "$line")"
    { grep -vF "$body" "$file"; echo "$line"; } > "$file.new"
    cat "$file.new" > "$file"
    rm -f "$file.new"
    echo "installed $user's key"
  fi
  chown "$user:$user" "$file"
  chmod 600 "$file"
}

# Asks for the admin's password, unless they have one. It's what sudo asks them for.
ensure_password() {
  [ "$(passwd -S "$admin" | awk '{print $2}')" = P ] && return
  local pw1 pw2 _
  for _ in 1 2 3; do
    read -rsp "New password for $admin (sudo asks for it): " pw1 || break
    echo
    read -rsp "Same again: " pw2 || break
    echo
    if [ -z "$pw1" ]; then
      echo "It can't be empty."
    elif [ "$pw1" != "$pw2" ]; then
      echo "They don't match."
    else
      chpasswd <<< "$admin:$pw1" && echo "set $admin's password" && return
    fi
  done
  die "$admin has no password, so sudo wouldn't work. Run bootstrap.sh again to set one."
}

ensure_user "$admin"
id -nG "$admin" | grep -qw sudo || { usermod -aG sudo "$admin" && echo "added $admin to sudo"; }
ensure_password
ensure_key "$admin" "$admin_key"

ensure_user deploy
ensure_key deploy "restrict $deploy_key"

if [ -e "$CLOUD_INIT_SUDOERS" ]; then
  rm -f "$CLOUD_INIT_SUDOERS" && echo "removed $CLOUD_INIT_SUDOERS (cloud-init's sudo grant)"
  visudo -c -q || die "visudo -c fails after removing $CLOUD_INIT_SUDOERS; fix the sudoers files before anything else"
fi

# ---------------------------------------------------------------------------
# Hostname
# ---------------------------------------------------------------------------

if [ "$(cat /etc/hostname 2> /dev/null)" != "$hostname" ]; then
  echo "$hostname" > /etc/hostname
  hostname "$hostname" 2> /dev/null || true # not allowed in a container
  echo "set the hostname to $hostname"
fi
# Stop cloud-init putting the provider's hostname back at the next boot.
if [ -d /etc/cloud/cloud.cfg.d ] && [ ! -e /etc/cloud/cloud.cfg.d/99-indy-center-hostname.cfg ]; then
  echo "preserve_hostname: true" > /etc/cloud/cloud.cfg.d/99-indy-center-hostname.cfg
fi

# ---------------------------------------------------------------------------
# Everything else, then deploy into docker (which apply.sh's Docker install creates), and
# the interim drop-in removed once apply.sh's own is in place
# ---------------------------------------------------------------------------

echo
echo "Running apply.sh:"
HOST_ADMIN="$admin" bash "$here/apply.sh"
applied=$?
echo

if getent group docker > /dev/null; then
  id -nG deploy | grep -qw docker || { usermod -aG docker deploy && echo "added deploy to docker"; }
else
  echo "No docker group yet (Docker didn't install), so deploy isn't in it." >&2
  applied=1
fi

# Only once apply.sh has finished, so password login never opens up between the two.
if [ "$applied" = 0 ] && [ -e "$INTERIM_DROPIN" ]; then
  rm -f "$INTERIM_DROPIN" && echo "removed $INTERIM_DROPIN; host/'s own drop-in covers it"
  systemctl try-reload-or-restart ssh || { echo "couldn't reload ssh" >&2; applied=1; }
fi

if [ "$applied" != 0 ]; then
  echo "Not finished: fix what is reported above, then run bootstrap.sh again." >&2
  exit 1
fi

cat <<EOF
Done. Before you close this root session, check from a second terminal that you can
still get in, since root can no longer log in over SSH:

  ssh $admin@<this server>
  sudo -v        # asks for $admin's password

Root's session stays open until you close it, so if that fails, fix it from here.
EOF
