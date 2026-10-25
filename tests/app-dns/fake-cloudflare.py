"""Stands in for Cloudflare's API in app-dns's tests. Never the real one.

It answers the three calls app-dns makes: list zones (GET /zones), look up one name's
records (GET /zones/<id>/dns_records?name=<name>), and create a record (POST to the same
path). Any other method or path gets a 405, so a test can tell it was tried. Every request
is appended to <out>/requests.jsonl as {"method", "path", "query", "auth", "body"}.

<state.json> sets what Cloudflare holds:

    {"token": "the one token it accepts",
     "zones": [{"id": "z1", "name": "flyindycenter.com"}],
     "records": [{"zone": "z1", "type": "CNAME", "name": "...", "content": "..."}],
     "fail": {"POST /zones/z1/dns_records": "the message to fail with"}}

A request whose method and path are in "fail" gets a 400 in Cloudflare's error shape.
The records it ends with are written to <out>/records.json after every write. The port
it listens on is written to <out>/port.

    python3 fake-cloudflare.py <state.json> <out>
"""
import http.server
import json
import os
import re
import sys
import urllib.parse

state_file, out = sys.argv[1:]
with open(state_file) as f:
    state = json.load(f)
records = state.get("records", [])


def log(entry):
    with open(os.path.join(out, "requests.jsonl"), "a") as f:
        f.write(json.dumps(entry) + "\n")


class Handler(http.server.BaseHTTPRequestHandler):
    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def error(self, code, message, error_code=1004):
        self.reply(code, {"success": False, "errors": [{"code": error_code, "message": message}],
                          "messages": [], "result": None})

    def handle_any(self):
        url = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(url.query)
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length).decode() if length else ""
        try:
            body = json.loads(raw) if raw else None
        except ValueError:
            body = raw
        log({"method": self.command, "path": url.path, "query": url.query,
             "auth": self.headers.get("Authorization"), "body": body})

        if self.headers.get("Authorization") != f"Bearer {state['token']}":
            return self.error(403, "Authentication error", 10000)
        key = f"{self.command} {url.path}"
        if key in state.get("fail", {}):
            return self.error(400, state["fail"][key])

        if self.command == "GET" and url.path == "/zones":
            zones = state.get("zones", [])
            if "name" in query:
                zones = [z for z in zones if z["name"] == query["name"][0]]
            return self.reply(200, {"success": True, "errors": [], "messages": [],
                                    "result": [{"id": z["id"], "name": z["name"]} for z in zones],
                                    "result_info": {"page": 1, "per_page": 50, "count": len(zones),
                                                    "total_count": len(zones), "total_pages": 1}})

        m = re.fullmatch(r"/zones/([^/]+)/dns_records", url.path)
        if m and any(z["id"] == m.group(1) for z in state.get("zones", [])):
            zone = m.group(1)
            if self.command == "GET":
                # Like Cloudflare: name matches the record's own name exactly, so a name
                # answered only by a wildcard has no records here.
                name = query.get("name", [None])[0]
                found = [dict(r, id=r.get("id", f"r{i}")) for i, r in enumerate(records)
                         if r["zone"] == zone and (name is None or r["name"].lower() == name.lower())]
                return self.reply(200, {"success": True, "errors": [], "messages": [], "result": found,
                                        "result_info": {"page": 1, "per_page": 100, "count": len(found),
                                                        "total_count": len(found), "total_pages": 1}})
            if self.command == "POST":
                if not isinstance(body, dict):
                    return self.error(400, "Invalid request body")
                record = dict(body, zone=zone, id=f"new{len(records)}")
                records.append(record)
                with open(os.path.join(out, "records.json"), "w") as f:
                    json.dump(records, f)
                return self.reply(200, {"success": True, "errors": [], "messages": [], "result": record})

        self.error(405, f"fake Cloudflare: {key} is not a call app-dns should make")

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = handle_any

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(out, "port.tmp"), "w") as f:
    f.write(str(server.server_port))
os.rename(os.path.join(out, "port.tmp"), os.path.join(out, "port"))
server.serve_forever()
