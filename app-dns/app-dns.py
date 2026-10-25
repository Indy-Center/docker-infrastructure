#!/usr/bin/env python3
"""app-dns: give an app's hostnames their DNS records, on the server it was deployed to.

Run by an app's deploy on the box, after the app is up:

    app-dns --app <app>          the hostnames in ~/apps/<app>'s Traefik Host() rules
    app-dns <hostname>...        these hostnames

For each hostname, in Cloudflare:

- no record of its own (a name only the *.flyindycenter.com wildcard answers has none):
  creates a DNS-only CNAME to this server's hostname;
- already a CNAME to this server: does nothing;
- any other record (a CNAME elsewhere, an A record, ...): warns, naming where it points,
  and leaves it alone.

It never changes or deletes a record, so switching a name to another server stays a step
a person takes by hand. A name outside the token's zone is skipped with a warning.

It uses Traefik's Cloudflare token, from ~/traefik/.env (Cloudflare accepts it only from
the servers' IPs), and this server's hostname from ~/app-dns/server-host. The deploy
writes both. Warnings and errors are printed as GitHub Actions annotations. It exits 1
when Cloudflare returns an error (the app is already up by then), and 0 otherwise,
warnings included.

APP_DNS_CLOUDFLARE_API overrides Cloudflare's API address, for the tests' fake.
"""
import ipaddress
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

API = os.environ.get("APP_DNS_CLOUDFLARE_API", "https://api.cloudflare.com/client/v4").rstrip("/")
HOME = os.path.expanduser("~")
TOKEN_FILE = os.path.join(HOME, "traefik", ".env")
SERVER_HOST_FILE = os.path.join(HOME, "app-dns", "server-host")
APPS = os.path.join(HOME, "apps")


class Failed(Exception):
    """Stops the run with an error message."""


def warn(message):
    print(f"::warning::{message}", flush=True)


def normal(name):
    return name.strip().rstrip(".").lower()


def read_token():
    try:
        with open(TOKEN_FILE) as f:
            for line in f:
                key, _, value = line.strip().partition("=")
                if key == "CF_DNS_API_TOKEN" and value:
                    return value.strip("'\"")
    except OSError as e:
        raise Failed(f"Can't read Traefik's Cloudflare token from {TOKEN_FILE}: {e.strerror}")
    raise Failed(f"No CF_DNS_API_TOKEN in {TOKEN_FILE}; docker-infrastructure's deploy writes it")


def read_server_host():
    try:
        with open(SERVER_HOST_FILE) as f:
            host = normal(f.read())
    except OSError as e:
        raise Failed(f"Can't read this server's hostname from {SERVER_HOST_FILE}: {e.strerror}; "
                     "docker-infrastructure's deploy writes it")
    if not host:
        raise Failed(f"{SERVER_HOST_FILE} is empty; docker-infrastructure's deploy writes it")
    return host


def is_ip(host):
    try:
        ipaddress.ip_address(host)
        return True
    except ValueError:
        return False


def app_hostnames(app):
    """Every hostname in an enabled service's Traefik Host() rules, as Compose resolves them."""
    folder = os.path.join(APPS, app)
    if not os.path.isdir(folder):
        raise Failed(f"No app folder {folder}")
    try:
        config = subprocess.run(["docker", "compose", "config", "--format", "json"], cwd=folder,
                                check=True, capture_output=True, text=True).stdout
    except (OSError, subprocess.CalledProcessError) as e:
        raise Failed(f"`docker compose config` failed in {folder}: {getattr(e, 'stderr', '') or e}")
    names = []
    for service in json.loads(config).get("services", {}).values():
        labels = service.get("labels") or {}
        if isinstance(labels, list):
            labels = dict(label.partition("=")[::2] for label in labels)
        if labels.get("traefik.enable", "").lower() != "true":
            continue
        for key, rule in sorted(labels.items()):
            if re.fullmatch(r"traefik\.http\.routers\.[^.]+\.rule", key):
                # Host(`a`) or Host(`a`, `b`); HostRegexp and HostSNI are other matchers.
                for args in re.findall(r"\bHost\(([^)]*)\)", rule):
                    names += re.findall(r"`([^`]+)`", args)
    return names


class Cloudflare:
    def __init__(self, token):
        self.token = token

    def call(self, method, path, query=None, body=None):
        url = API + path + ("?" + urllib.parse.urlencode(query) if query else "")
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(url, data=data, method=method, headers={
            "Authorization": f"Bearer {self.token}", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                reply = json.load(response)
        except urllib.error.HTTPError as e:
            try:
                reply = json.load(e)
            except ValueError:
                raise Failed(f"Cloudflare: {method} {path} returned HTTP {e.code}")
        except (urllib.error.URLError, OSError, ValueError) as e:
            raise Failed(f"Cloudflare: {method} {path} failed: {getattr(e, 'reason', e)}")
        if not reply.get("success"):
            messages = "; ".join(f"{err.get('message')} (code {err.get('code')})"
                                 for err in reply.get("errors") or []) or "no message"
            raise Failed(f"Cloudflare: {method} {path}: {messages}")
        return reply["result"]


def zone_for(name, zones):
    """The zone holding name: the longest zone name it equals or ends with."""
    inside = [z for z in zones if name == normal(z["name"]) or name.endswith("." + normal(z["name"]))]
    return max(inside, key=lambda z: len(z["name"]), default=None)


def describe(record):
    return f"{record.get('type')} {record.get('content')}"


def ensure(cf, zone, name, server_host):
    """Applies the rule to one name, inside zone. Raises Failed on a Cloudflare error."""
    records = cf.call("GET", f"/zones/{zone['id']}/dns_records", {"name": name, "per_page": 100})
    if not records:
        cf.call("POST", f"/zones/{zone['id']}/dns_records", body={
            "type": "CNAME", "name": name, "content": server_host, "proxied": False, "ttl": 1,
            "comment": f"Made by app-dns, on a deploy to {server_host}"})
        print(f"{name}: created a DNS-only CNAME to {server_host}", flush=True)
    elif any(r.get("type") == "CNAME" and normal(r.get("content", "")) == server_host for r in records):
        print(f"{name}: already a CNAME to {server_host}; nothing to do", flush=True)
    else:
        warn(f"{name} points elsewhere ({', '.join(describe(r) for r in records)}), not at "
             f"{server_host}; left as it is. Switching it is done by hand, in the app's move.")


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0 if argv else 2
    if argv[0] == "--app":
        if len(argv) != 2:
            print("usage: app-dns --app <app>  |  app-dns <hostname>...", file=sys.stderr)
            return 2
    try:
        names = app_hostnames(argv[1]) if argv[0] == "--app" else argv
        names = list(dict.fromkeys(normal(n) for n in names if normal(n)))
        if not names:
            print(f"{argv[1]} has no Traefik Host() rules; no DNS records to make")
            return 0
        server_host = read_server_host()
        token = read_token()
        if is_ip(server_host):
            warn(f"This server's host setting is an IP address ({server_host}), not a hostname, "
                 "so app records can't be CNAMEs to it; no records made. Make them by hand.")
            return 0
        cf = Cloudflare(token)
        zones = cf.call("GET", "/zones", {"per_page": 50})
    except Failed as e:
        print(f"::error::{e}", flush=True)
        return 1

    failed = False
    for name in names:
        zone = zone_for(name, zones)
        if zone is None:
            warn(f"{name} is not in the Cloudflare zone this token can edit "
                 f"({', '.join(z['name'] for z in zones) or 'none'}); skipped")
            continue
        try:
            ensure(cf, zone, name, server_host)
        except Failed as e:
            print(f"::error::{name}: {e}", flush=True)
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
