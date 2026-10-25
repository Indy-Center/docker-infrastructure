#!/usr/bin/env bash
# Tests that the deploy writes Traefik's Cloudflare token onto each server from the
# CF_DNS_API_TOKEN repo secret, and that the staging check writes its own copy the same way.
# It runs each workflow's own step, with a fake ssh that runs the server's side in a temp
# folder standing in for deploy's home, and logs each command the step sends there.
#
#   bash tests/traefik/token-test.sh
#
# Needs rsync and python3 with PyYAML.
set -uo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

# ssh vps <command>: runs the command in the fake home, as the server would, and logs it.
cat > "$T/bin/ssh" <<EOF
#!/usr/bin/env bash
while [ "\$1" != vps ]; do shift; done
shift
echo "\$*" >> "$T/remote-commands"
export HOME="$T/home"
cd "\$HOME" && exec bash -c "\$*"
EOF
chmod +x "$T/bin/ssh"

failed=0
fail() { echo "FAIL: $*"; failed=1; }

# step WORKFLOW JOB NAME BEFORE: the step's shell, exactly as the workflow has it, in
# $T/step.sh. Fails unless the step takes CF_DNS_API_TOKEN from the repo secret of that
# name, and comes before the step named BEFORE, which starts Traefik.
step() {
  python3 - "$repo/.github/workflows/$1" "$2" "$3" "$4" > "$T/step.sh" <<'EOF'
import sys, yaml
workflow, job, name, before = sys.argv[1:]
steps = yaml.safe_load(open(workflow))["jobs"][job]["steps"]
names = [s.get("name") for s in steps]
if name not in names:
    sys.exit(f"no step named {name!r} in {workflow}")
if before not in names or names.index(name) > names.index(before):
    sys.exit(f"{name!r} doesn't come before {before!r} in {workflow}")
found = [steps[names.index(name)]]
env = found[0].get("env", {})
if env.get("CF_DNS_API_TOKEN") != "${{ secrets.CF_DNS_API_TOKEN }}":
    sys.exit(f"{name!r} doesn't take CF_DNS_API_TOKEN from secrets.CF_DNS_API_TOKEN")
print(found[0]["run"])
EOF
}

# run TOKEN: runs $T/step.sh as Actions would, from the repo, with the secret set to TOKEN.
# Its output goes to $T/out.
run() {
  rm -f "$T/remote-commands"
  (cd "$repo" && PATH="$T/bin:$PATH" RSYNC_RSH="$T/bin/ssh" SERVER=VANDERBILT \
    CF_DNS_API_TOKEN="$1" bash --noprofile --norc -eo pipefail "$T/step.sh") > "$T/out" 2>&1
}

# check_writes WORKFLOW JOB NAME BEFORE FILE: the step writes FILE (under deploy's home), mode
# 600, holding only the token, over an older hand-made one, and never prints the token or
# puts it on a command line. With the secret empty, it fails naming the secret, and never
# reaches the server.
check_writes() {
  local workflow="$1" job="$2" name="$3" before="$4" file="$5" what token mode
  what="$workflow, \"$name\""
  rm -rf "${T:?}/home" && mkdir -p "$T/home"
  if ! step "$workflow" "$job" "$name" "$before"; then
    fail "$what: the step is missing, misplaced, or doesn't read the secret"
    return
  fi

  # A server set up by hand: an old token in a file anyone can read.
  mkdir -p "$(dirname "$T/home/$file")"
  echo "CF_DNS_API_TOKEN=old-hand-made-token" > "$T/home/$file"
  chmod 644 "$T/home/$file"

  token="test-token-$RANDOM$RANDOM"
  if run "$token"; then
    [ "$(cat "$T/home/$file")" = "CF_DNS_API_TOKEN=$token" ] ||
      fail "$what: ~/$file holds [$(cat "$T/home/$file")], not CF_DNS_API_TOKEN=$token"
    mode="$(stat -c %a "$T/home/$file")"
    [ "$mode" = 600 ] || fail "$what: ~/$file is mode $mode, not 600"
    ! grep -qF "$token" "$T/out" || fail "$what: the token was printed: $(cat "$T/out")"
    ! grep -qF "$token" "$T/remote-commands" || fail "$what: the token was on ssh's command line"
    [ -z "$(find "$T/home" -name '*.tmp')" ] || fail "$what: left a temp file: $(find "$T/home" -name '*.tmp')"
  else
    fail "$what: the step failed: $(cat "$T/out")"
  fi

  echo "CF_DNS_API_TOKEN=kept" > "$T/home/$file"
  if run ""; then
    fail "$what: an empty secret didn't fail the step"
  else
    grep -q '^::error::.*CF_DNS_API_TOKEN' "$T/out" ||
      fail "$what: an empty secret failed without an ::error:: naming CF_DNS_API_TOKEN: $(cat "$T/out")"
  fi
  [ ! -e "$T/remote-commands" ] || fail "$what: an empty secret still reached the server: $(cat "$T/remote-commands")"
  [ "$(cat "$T/home/$file")" = "CF_DNS_API_TOKEN=kept" ] || fail "$what: an empty secret changed ~/$file"
}

check_writes build-and-deploy.yml build-and-deploy "Write Traefik's Cloudflare token" \
  "docker compose up -d" traefik/.env
check_writes staging.yml staging "Write the Cloudflare token" \
  "Start staging Traefik" traefik-staging/.env

# The deploy's sync of traefik/ (with --delete) leaves the written .env alone.
rm -rf "${T:?}/home" && mkdir -p "$T/home/traefik"
echo "CF_DNS_API_TOKEN=written" > "$T/home/traefik/.env"
python3 - "$repo/.github/workflows/build-and-deploy.yml" > "$T/step.sh" <<'EOF'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["build-and-deploy"]["steps"]
print([s["run"] for s in steps if s.get("name") == "Sync traefik/ to ~/traefik/"][0])
EOF
run "unused" || fail "the sync of traefik/ failed: $(cat "$T/out")"
[ "$(cat "$T/home/traefik/.env" 2>/dev/null)" = "CF_DNS_API_TOKEN=written" ] ||
  fail "the sync of traefik/ removed or changed ~/traefik/.env"

[ "$failed" = 0 ] && echo "ok   the deploy and the staging check write the Cloudflare token from its secret"
exit "$failed"
