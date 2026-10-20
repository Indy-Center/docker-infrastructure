#!/usr/bin/env bash
# Installs the two programs the runner needs, age and rclone, at pinned versions, into
# the folder given (on the VPS, ~/backup-runner/bin). Each download is checked against
# the checksum below before it is used. Nothing is installed system-wide, so no sudo.
#
#   bash install-tools.sh ~/backup-runner/bin
#
# To upgrade: change a version, download both of its linux archives, and replace the
# checksums with their `sha256sum` (rclone also publishes SHA256SUMS next to each release).
set -euo pipefail

bin_dir="${1:?usage: install-tools.sh <bin-dir>}"

AGE_VERSION=v1.3.2
RCLONE_VERSION=v1.75.1

case "$(uname -m)" in
  x86_64)
    arch=amd64
    age_sha=cbe24006683f8eb669266162894b9a522a1af52f2665fbc63a4bb032ed26ac10
    rclone_sha=982b5aa772841168f8e380f139e9e787b2a105403e32b94da8676a0e1c0a13ab
    ;;
  aarch64)
    arch=arm64
    age_sha=6b8dc4333c53a5a57c9e5834e3a48f92605d7154014cd07269ff3327db5d37f4
    rclone_sha=03f2504174034b6d004152ed7369251c9a9ec1f7e0836eda420f5c7a5ec0dff9
    ;;
  *)
    echo "install-tools.sh: no pinned builds for $(uname -m)" >&2
    exit 1
    ;;
esac

mkdir -p "$bin_dir"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Already at the pinned version: nothing to do, so a redeploy downloads nothing.
have_version() { [ -x "$bin_dir/$1" ] && "$bin_dir/$1" --version 2>/dev/null | grep -qF "$2"; }

# Downloads a URL into the work folder and stops unless its checksum matches.
fetch() {
  local url="$1" sha="$2" file="$work/${1##*/}"
  curl -fsSL --retry 3 -o "$file" "$url"
  echo "$sha  $file" | sha256sum -c --quiet -
}

if ! have_version age "$AGE_VERSION"; then
  fetch "https://github.com/FiloSottile/age/releases/download/$AGE_VERSION/age-$AGE_VERSION-linux-$arch.tar.gz" "$age_sha"
  tar -xzf "$work/age-$AGE_VERSION-linux-$arch.tar.gz" -C "$work"
  install -m 755 "$work/age/age" "$work/age/age-keygen" "$bin_dir/"
  echo "installed age $AGE_VERSION"
fi

if ! have_version rclone "$RCLONE_VERSION"; then
  fetch "https://downloads.rclone.org/$RCLONE_VERSION/rclone-$RCLONE_VERSION-linux-$arch.zip" "$rclone_sha"
  # unzip is not always on a fresh server; Python's zipfile does the same job.
  if command -v unzip >/dev/null; then
    unzip -q "$work/rclone-$RCLONE_VERSION-linux-$arch.zip" -d "$work"
  else
    python3 -m zipfile -e "$work/rclone-$RCLONE_VERSION-linux-$arch.zip" "$work"
  fi
  install -m 755 "$work/rclone-$RCLONE_VERSION-linux-$arch/rclone" "$bin_dir/"
  echo "installed rclone $RCLONE_VERSION"
fi
