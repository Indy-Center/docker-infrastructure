"""Stands in for Discord and the status page in the runner's tests.

Every POST is saved as <out>/<first path part>/<n>.body, with its Authorization header,
if any, in <n>.auth. Requests to a path starting /fail get a 500, for testing an
endpoint that is down. The port it listens on is written to <out>/port.

    python3 fake-endpoint.py <out>
"""
import http.server
import os
import sys

out = sys.argv[1]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        name = self.path.strip("/").split("/")[0] or "root"
        folder = os.path.join(out, name)
        os.makedirs(folder, exist_ok=True)
        n = len([f for f in os.listdir(folder) if f.endswith(".body")]) + 1
        with open(os.path.join(folder, f"{n}.body"), "wb") as f:
            f.write(body)
        if self.headers.get("Authorization"):
            with open(os.path.join(folder, f"{n}.auth"), "w") as f:
                f.write(self.headers["Authorization"])
        self.send_response(500 if name == "fail" else 204)
        self.end_headers()

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(out, "port.tmp"), "w") as f:
    f.write(str(server.server_port))
os.rename(os.path.join(out, "port.tmp"), os.path.join(out, "port"))
server.serve_forever()
