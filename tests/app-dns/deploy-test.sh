#!/usr/bin/env bash
# Tests the workflow steps around app-dns: docker-infrastructure's deploy writes the
# server's hostname, ships app-dns/ and installs the `app-dns` command, and the example
# app's deploy runs it after the app is up. Each step's own shell runs as the workflow has
# it, with a fake ssh that runs the server's side in a temp folder standing in for
# deploy's home. Cloudflare is never called: the installed command only prints its help.
#
#   bash tests/app-dns/deploy-test.sh
#
# Needs rsync and python3 with PyYAML.
set -uo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/bin"

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

# step WORKFLOW JOB NAME: the step's shell, exactly as the workflow has it, in $T/step.sh,
# and its env in $T/step.env. Fails if there's no such step.
step() {
  python3 - "$1" "$2" "$3" "$T" <<'EOF'
import sys, yaml
workflow, job, name, out = sys.argv[1:]
steps = yaml.safe_load(open(workflow))["jobs"][job]["steps"]
found = [s for s in steps if s.get("name") == name]
if not found:
    sys.exit(f"no step named {name!r} in {workflow}")
open(f"{out}/step.sh", "w").write(found[0]["run"])
open(f"{out}/step.env", "w").write("".join(f"{k}={v}\n" for k, v in found[0].get("env", {}).items()))
EOF
}

# order WORKFLOW JOB FIRST SECOND: FIRST comes before SECOND.
order() {
  python3 - "$@" <<'EOF'
import sys, yaml
workflow, job, first, second = sys.argv[1:]
names = [s.get("name") for s in yaml.safe_load(open(workflow))["jobs"][job]["steps"]]
sys.exit(0 if first in names and second in names and names.index(first) < names.index(second) else 1)
EOF
}

# run [VAR=value...]: runs $T/step.sh as Actions would, from the repo. Output in $T/out.
run() {
  (cd "$repo" && env PATH="$T/bin:$PATH" RSYNC_RSH="$T/bin/ssh" "$@" \
    bash --noprofile --norc -eo pipefail "$T/step.sh") > "$T/out" 2>&1
}

deploy="$repo/.github/workflows/build-and-deploy.yml"

# --- docker-infrastructure's deploy ---------------------------------------

# The server's hostname, from its <SERVER>_HOST setting, lands in ~/app-dns/server-host.
if step "$deploy" build-and-deploy "Write the server's hostname for app-dns"; then
  grep -qxF "HOST=\${{ vars[format('{0}_HOST', matrix.server)] }}" "$T/step.env" ||
    fail "the hostname step doesn't take HOST from the server's _HOST setting: $(cat "$T/step.env")"
  run HOST=alexandria.flyzid.org || fail "the hostname step failed: $(cat "$T/out")"
  [ "$(cat "$T/home/app-dns/server-host" 2> /dev/null)" = alexandria.flyzid.org ] ||
    fail "app-dns/server-host in deploy's home isn't the server's hostname"
  run HOST=other.example.net || fail "the hostname step failed a second time: $(cat "$T/out")"
  [ "$(cat "$T/home/app-dns/server-host")" = other.example.net ] || fail "a second deploy didn't rewrite server-host"
  [ -z "$(find "$T/home" -name '*.tmp')" ] || fail "left a temp file"
else
  fail "no step writes the server's hostname for app-dns"
fi

# The sync ships app-dns/, removing dropped files but keeping server-host.
touch "$T/home/app-dns/dropped-from-the-repo"
if step "$deploy" build-and-deploy "Sync app-dns/ to ~/app-dns/"; then
  run || fail "the sync failed: $(cat "$T/out")"
  cmp -s "$repo/app-dns/app-dns.py" "$T/home/app-dns/app-dns.py" || fail "the sync didn't ship app-dns.py"
  [ ! -e "$T/home/app-dns/dropped-from-the-repo" ] || fail "the sync kept a file dropped from the repo"
  [ "$(cat "$T/home/app-dns/server-host" 2> /dev/null)" = other.example.net ] || fail "the sync removed server-host"
else
  fail "no step syncs app-dns/"
fi

# The install puts `app-dns` in ~/.local/bin, where an app's deploy runs it by full path.
if step "$deploy" build-and-deploy "Install the app-dns command"; then
  run || fail "the install failed: $(cat "$T/out")"
  run || fail "the install failed a second time: $(cat "$T/out")"
  HOME="$T/home" "$T/home/.local/bin/app-dns" --help 2>&1 | grep -q '^app-dns: give an app' ||
    fail ".local/bin/app-dns in deploy's home doesn't run app-dns"
else
  fail "no step installs the app-dns command"
fi

order "$deploy" build-and-deploy "Write Traefik's Cloudflare token" "Install the app-dns command" ||
  fail "app-dns is installed before Traefik's token is written"

# --- The example app's deploy ---------------------------------------------

example="$repo/examples/app/.github/workflows/build-and-deploy.yml"
order "$example" build-and-deploy "docker compose up -d" "DNS record" ||
  fail "the example app has no \"DNS record\" step after \"docker compose up -d\""
if step "$example" build-and-deploy "DNS record"; then
  # A stand-in for the installed command, that logs how it was called.
  mkdir -p "$T/home/.local/bin"
  printf '#!/bin/sh\necho "$@" > "%s/called"\n' "$T" > "$T/home/.local/bin/app-dns"
  chmod +x "$T/home/.local/bin/app-dns"
  run APP=example-app || fail "the example app's DNS step failed: $(cat "$T/out")"
  [ "$(cat "$T/called" 2> /dev/null)" = "--app example-app" ] ||
    fail "the example app's DNS step didn't run app-dns --app example-app"
  printf '#!/bin/sh\nexit 1\n' > "$T/home/.local/bin/app-dns"
  ! run APP=example-app || fail "the example app's DNS step passed when app-dns failed"
fi

[ "$failed" = 0 ] && echo "ok   the deploy installs app-dns, and the example app runs it after up -d"
exit "$failed"
