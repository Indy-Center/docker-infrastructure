#!/usr/bin/env bash
# Tests for app-dns, the deploy's DNS helper (app-dns/app-dns.py). Each test sets up a fake
# deploy home (Traefik's token in ~/traefik/.env, the server's hostname in
# ~/app-dns/server-host) and a fake Cloudflare API (fake-cloudflare.py) holding the
# records the test needs, runs app-dns once, and checks what it printed, its exit code,
# and every request the fake received. Nothing here ever reaches the real Cloudflare API:
# the API's address always points at the fake, and any other HTTPS request goes to a
# proxy that isn't there.
#
#   bash tests/app-dns/test.sh            # every test
#   bash tests/app-dns/test.sh wildcard   # tests whose name contains "wildcard"
#
# Needs python3. The --app tests also need `docker compose`, and pass without running
# when it is missing.
set -uo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
here="$repo/tests/app-dns"
TOKEN="test-token-$RANDOM$RANDOM"
SERVER_HOST=alexandria.flyzid.org

fail() { echo "    $*"; return 1; }
assert_eq() { [ "$1" = "$2" ] || fail "expected [$2], got [$1]${3:+ ($3)}"; }
assert_out() { grep -qF -- "$1" "$T/out" || fail "output doesn't say [$1]: $(cat "$T/out")"; }

# A fresh fake home, and a Cloudflare holding the zone flyindycenter.com and the records
# given as JSON objects (zone z1 is filled in).
setup() {
  T="$(mktemp -d)"
  mkdir -p "$T/home/traefik" "$T/home/app-dns" "$T/api"
  printf 'CF_DNS_API_TOKEN=%s\n' "$TOKEN" > "$T/home/traefik/.env"
  printf '%s\n' "$SERVER_HOST" > "$T/home/app-dns/server-host"
  given_records
}

# given_records [JSON-OBJECT...]: what Cloudflare holds in flyindycenter.com.
given_records() {
  python3 - "$TOKEN" "$@" > "$T/state.json" <<'EOF'
import json, sys
token, *records = sys.argv[1:]
print(json.dumps({"token": token, "zones": [{"id": "z1", "name": "flyindycenter.com"}],
                  "records": [dict(json.loads(r), zone="z1") for r in records]}))
EOF
}

# given_failure "METHOD PATH" MESSAGE: Cloudflare answers that request with an error.
given_failure() {
  python3 - "$T/state.json" "$1" "$2" <<'EOF'
import json, sys
path, key, message = sys.argv[1:]
state = json.load(open(path))
state.setdefault("fail", {})[key] = message
json.dump(state, open(path, "w"))
EOF
}

# run_app_dns ARG...: runs app-dns against a fresh fake Cloudflare. Output in $T/out, exit
# code in $T/rc, requests in $T/api/requests.jsonl.
run_app_dns() {
  rm -f "$T/api/"*
  python3 "$here/fake-cloudflare.py" "$T/state.json" "$T/api" &
  local fake=$!
  for _ in $(seq 50); do [ -e "$T/api/port" ] && break; sleep 0.1; done
  touch "$T/api/requests.jsonl"
  HOME="$T/home" APP_DNS_CLOUDFLARE_API="http://127.0.0.1:$(cat "$T/api/port")" \
    https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 no_proxy=127.0.0.1 \
    python3 "$repo/app-dns/app-dns.py" "$@" > "$T/out" 2>&1
  echo $? > "$T/rc"
  kill "$fake" 2> /dev/null
  wait "$fake" 2> /dev/null
  return 0
}

# requests [METHOD]: one line per request the fake received ("METHOD path?query").
requests() {
  python3 - "$T/api/requests.jsonl" "${1:-}" <<'EOF'
import json, sys
for line in open(sys.argv[1]):
    r = json.loads(line)
    if not sys.argv[2] or r["method"] == sys.argv[2]:
        print(r["method"], r["path"] + ("?" + r["query"] if r["query"] else ""))
EOF
}

# writes: every request that isn't a GET. app-dns only ever creates, with a POST.
writes() { requests | grep -v '^GET ' || true; }

# created: the body of each POST, as compact JSON with sorted keys.
created() {
  python3 - "$T/api/requests.jsonl" <<'EOF'
import json, sys
for line in open(sys.argv[1]):
    r = json.loads(line)
    if r["method"] == "POST":
        b = r["body"]
        print(json.dumps({k: b.get(k) for k in ("type", "name", "content", "proxied")}, sort_keys=True))
EOF
}

cname_to_server() {
  printf '{"content": "%s", "name": "%s", "proxied": false, "type": "CNAME"}' "$SERVER_HOST" "$1"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test_no_record_creates_one_dns_only_cname_to_the_server() {
  run_app_dns newapp.flyindycenter.com
  assert_eq "$(cat "$T/rc")" 0 "exit code; output: $(cat "$T/out")" || return 1
  assert_eq "$(writes)" "POST /zones/z1/dns_records" || return 1
  assert_eq "$(created)" "$(cname_to_server newapp.flyindycenter.com)" || return 1
  assert_out "newapp.flyindycenter.com: created a DNS-only CNAME to $SERVER_HOST"
}

test_a_cname_already_to_this_server_writes_nothing() {
  given_records '{"type": "CNAME", "name": "social.flyindycenter.com", "content": "alexandria.flyzid.org", "proxied": false}'
  run_app_dns social.flyindycenter.com
  assert_eq "$(cat "$T/rc")" 0 "exit code; output: $(cat "$T/out")" || return 1
  assert_eq "$(writes)" "" || return 1
  assert_out "social.flyindycenter.com: already a CNAME to $SERVER_HOST"
}

test_the_hostname_is_matched_whatever_its_case_or_trailing_dot() {
  given_records '{"type": "CNAME", "name": "social.flyindycenter.com", "content": "Alexandria.FlyZID.org.", "proxied": false}'
  run_app_dns Social.FlyIndyCenter.com.
  assert_eq "$(cat "$T/rc")" 0 "exit code; output: $(cat "$T/out")" || return 1
  assert_eq "$(writes)" "" || return 1
  assert_out "already a CNAME to $SERVER_HOST"
}

test_a_cname_elsewhere_is_left_alone_with_a_warning() {
  given_records '{"type": "CNAME", "name": "wiki.flyindycenter.com", "content": "vanderbilt.example.net", "proxied": false}'
  run_app_dns wiki.flyindycenter.com
  assert_eq "$(cat "$T/rc")" 0 "exit code; output: $(cat "$T/out")" || return 1
  assert_eq "$(writes)" "" || return 1
  assert_out "::warning::wiki.flyindycenter.com points elsewhere (CNAME vanderbilt.example.net)"
  assert_out "left as it is"
}

test_an_a_record_is_left_alone_with_a_warning() {
  given_records '{"type": "A", "name": "cms.flyindycenter.com", "content": "203.0.113.7", "proxied": true}'
  run_app_dns cms.flyindycenter.com
  assert_eq "$(cat "$T/rc")" 0 "exit code; output: $(cat "$T/out")" || return 1
  assert_eq "$(writes)" "" || return 1
  assert_out "::warning::cms.flyindycenter.com points elsewhere (A 203.0.113.7)"
}

test_a_name_answered_only_by_the_wildcard_gets_its_own_record() {
  given_records '{"type": "A", "name": "*.flyindycenter.com", "content": "203.0.113.7", "proxied": false}'
  run_app_dns newapp.flyindycenter.com
  assert_eq "$(cat "$T/rc")" 0 "exit code; output: $(cat "$T/out")" || return 1
  assert_eq "$(created)" "$(cname_to_server newapp.flyindycenter.com)"
}

test_a_cloudflare_error_on_create_fails_with_the_apis_message() {
  given_failure "POST /zones/z1/dns_records" "Record quota exceeded."
  run_app_dns newapp.flyindycenter.com
  assert_eq "$(cat "$T/rc")" 1 "exit code; output: $(cat "$T/out")" || return 1
  assert_out "::error::"
  assert_out "Record quota exceeded."
}

test_a_cloudflare_error_on_lookup_fails_and_writes_nothing() {
  given_failure "GET /zones/z1/dns_records" "Invalid request headers"
  run_app_dns newapp.flyindycenter.com
  assert_eq "$(cat "$T/rc")" 1 "exit code; output: $(cat "$T/out")" || return 1
  assert_eq "$(writes)" "" || return 1
  assert_out "Invalid request headers"
}

test_a_refused_token_fails_with_the_apis_message() {
  printf 'CF_DNS_API_TOKEN=%s\n' "not-the-token" > "$T/home/traefik/.env"
  run_app_dns newapp.flyindycenter.com
  assert_eq "$(cat "$T/rc")" 1 "exit code; output: $(cat "$T/out")" || return 1
  assert_eq "$(writes)" "" || return 1
  assert_out "Authentication error"
}

test_a_cloudflare_error_listing_zones_fails_and_looks_nothing_up() {
  given_failure "GET /zones" "Unauthorized to access requested resource"
  run_app_dns newapp.flyindycenter.com
  assert_eq "$(cat "$T/rc")" 1 || return 1
  assert_eq "$(requests)" "GET /zones?per_page=50" || return 1
  assert_out "Unauthorized to access requested resource"
}

test_names_outside_the_tokens_zone_are_skipped_with_a_warning() {
  run_app_dns training.example.org newapp.flyindycenter.com flyindycenter.com.evil.net
  assert_eq "$(cat "$T/rc")" 0 "exit code; output: $(cat "$T/out")" || return 1
  assert_out "::warning::training.example.org is not in the Cloudflare zone this token can edit (flyindycenter.com); skipped"
  assert_out "::warning::flyindycenter.com.evil.net is not in"
  # Only the name inside the zone was looked up, and only it was created.
  assert_eq "$(requests GET | grep -c dns_records)" 1 || return 1
  assert_eq "$(created)" "$(cname_to_server newapp.flyindycenter.com)"
}

test_the_token_comes_from_traefiks_env_file_and_is_never_printed() {
  run_app_dns newapp.flyindycenter.com
  assert_eq "$(python3 -c 'import json,sys; print({json.loads(l)["auth"] for l in open(sys.argv[1])})' "$T/api/requests.jsonl")" \
    "{'Bearer $TOKEN'}" || return 1
  ! grep -qF "$TOKEN" "$T/out" || fail "the token was printed: $(cat "$T/out")"
}

test_a_name_given_twice_is_created_once() {
  run_app_dns newapp.flyindycenter.com NewApp.flyindycenter.com
  assert_eq "$(writes)" "POST /zones/z1/dns_records"
}

test_never_edits_or_deletes_a_record() {
  given_records \
    '{"type": "CNAME", "name": "social.flyindycenter.com", "content": "alexandria.flyzid.org", "proxied": false}' \
    '{"type": "CNAME", "name": "wiki.flyindycenter.com", "content": "vanderbilt.example.net", "proxied": true}' \
    '{"type": "A", "name": "cms.flyindycenter.com", "content": "203.0.113.7", "proxied": true}' \
    '{"type": "AAAA", "name": "v6.flyindycenter.com", "content": "2001:db8::1", "proxied": false}' \
    '{"type": "TXT", "name": "txt.flyindycenter.com", "content": "hello", "proxied": false}'
  run_app_dns social.flyindycenter.com wiki.flyindycenter.com cms.flyindycenter.com \
    v6.flyindycenter.com txt.flyindycenter.com newapp.flyindycenter.com
  assert_eq "$(cat "$T/rc")" 0 "exit code; output: $(cat "$T/out")" || return 1
  assert_eq "$(writes)" "POST /zones/z1/dns_records" || return 1
  assert_eq "$(created)" "$(cname_to_server newapp.flyindycenter.com)"
}

test_a_server_known_only_by_ip_makes_no_record() {
  printf '203.0.113.9\n' > "$T/home/app-dns/server-host"
  run_app_dns newapp.flyindycenter.com
  assert_eq "$(cat "$T/rc")" 0 "exit code; output: $(cat "$T/out")" || return 1
  assert_eq "$(writes)" "" || return 1
  assert_out "::warning::This server's host setting is an IP address (203.0.113.9)"
}

test_without_the_servers_hostname_it_fails_before_calling_cloudflare() {
  rm "$T/home/app-dns/server-host"
  run_app_dns newapp.flyindycenter.com
  assert_eq "$(cat "$T/rc")" 1 || return 1
  assert_eq "$(requests)" "" || return 1
  assert_out "::error::"
  assert_out "server-host"
}

test_without_the_token_it_fails_before_calling_cloudflare() {
  printf 'OTHER=1\n' > "$T/home/traefik/.env"
  run_app_dns newapp.flyindycenter.com
  assert_eq "$(cat "$T/rc")" 1 || return 1
  assert_eq "$(requests)" "" || return 1
  assert_out "CF_DNS_API_TOKEN"
}

test_no_names_is_a_usage_error() {
  run_app_dns
  assert_eq "$(cat "$T/rc")" 2 || return 1
  assert_eq "$(requests)" ""
}

test_help_explains_it_and_calls_nothing() {
  run_app_dns --help
  assert_eq "$(cat "$T/rc")" 0 || return 1
  assert_out "never changes or deletes" || return 1
  assert_eq "$(requests)" ""
}

# --app APP reads the hostnames from ~/apps/APP's Traefik Host() rules, through
# `docker compose config`, so it sees what the deploy just started.
have_compose() { docker compose version > /dev/null 2>&1; }

test_app_reads_the_example_apps_host_rule() {
  have_compose || { echo "skipped: no docker compose" >&3; return 0; }
  mkdir -p "$T/home/apps/example-app"
  cp "$repo/examples/app/deploy/docker-compose.yml" "$T/home/apps/example-app/"
  run_app_dns --app example-app
  assert_eq "$(cat "$T/rc")" 0 "exit code; output: $(cat "$T/out")" || return 1
  assert_eq "$(created)" "$(cname_to_server example-app.flyindycenter.com)"
}

test_app_reads_every_host_in_every_enabled_router() {
  have_compose || { echo "skipped: no docker compose" >&3; return 0; }
  mkdir -p "$T/home/apps/many"
  cat > "$T/home/apps/many/docker-compose.yml" <<'EOF'
services:
  web:
    image: traefik/whoami
    labels:
      - traefik.enable=true
      - traefik.http.routers.moodle.rule=Host(`training.flyindycenter.com`) && PathPrefix(`/moodle`)
      - traefik.http.routers.alias.rule=Host(`a.flyindycenter.com`) || Host(`b.flyindycenter.com`)
      - traefik.http.routers.again.rule=Host(`training.flyindycenter.com`)
      - traefik.http.routers.regexp.rule=HostRegexp(`^.+\.flyindycenter\.com$`)
  hidden:
    image: traefik/whoami
    labels:
      - traefik.enable=false
      - traefik.http.routers.hidden.rule=Host(`hidden.flyindycenter.com`)
EOF
  run_app_dns --app many
  assert_eq "$(cat "$T/rc")" 0 "exit code; output: $(cat "$T/out")" || return 1
  assert_eq "$(created | sort | tr '\n' ' ')" \
    "$( (cname_to_server a.flyindycenter.com; echo; cname_to_server b.flyindycenter.com; echo
      cname_to_server training.flyindycenter.com; echo) | sort | tr '\n' ' ')"
}

test_app_with_no_host_rules_says_so_and_calls_nothing() {
  have_compose || { echo "skipped: no docker compose" >&3; return 0; }
  mkdir -p "$T/home/apps/quiet"
  printf 'services:\n  worker:\n    image: traefik/whoami\n' > "$T/home/apps/quiet/docker-compose.yml"
  run_app_dns --app quiet
  assert_eq "$(cat "$T/rc")" 0 "exit code; output: $(cat "$T/out")" || return 1
  assert_eq "$(requests)" "" || return 1
  assert_out "no Traefik Host() rules"
}

test_app_that_is_not_there_fails() {
  run_app_dns --app missing
  assert_eq "$(cat "$T/rc")" 1 || return 1
  assert_eq "$(requests)" ""
}

# ---------------------------------------------------------------------------

run_one() {
  setup
  "$1"
  local rc=$?
  rm -rf "$T"
  return "$rc"
}

passed=0
failed=0
out="$(mktemp)"
exec 3>&1
for t in $(declare -F | awk '{print $3}' | grep '^test_' | grep -- "${1:-}"); do
  if run_one "$t" > "$out" 2>&1; then
    echo "ok   $t"
    passed=$((passed + 1))
  else
    echo "FAIL $t"
    sed 's/^/    | /' "$out" | tail -30
    failed=$((failed + 1))
  fi
done
rm -f "$out"
echo "$passed passed, $failed failed"
[ "$failed" = 0 ]
