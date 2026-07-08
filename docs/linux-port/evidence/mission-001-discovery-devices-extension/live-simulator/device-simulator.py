#!/usr/bin/env python3
import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT_ROLES = {
    18081: "pixelclock",
    18082: "cast",
    18083: "homeassistant",
    18084: "smarthub",
}

class Handler(BaseHTTPRequestHandler):
    log_path = None

    def _body(self):
        length = int(self.headers.get("content-length", "0") or "0")
        if length == 0:
            return {}
        try:
            return json.loads(self.rfile.read(length).decode("utf-8"))
        except Exception:
            return {"raw": "<unparseable>"}

    def _send(self, payload, status=200):
        payload = {
            **payload,
            "simulator": True,
            "role": PORT_ROLES.get(self.server.server_port, "unknown"),
            "port": self.server.server_port,
        }
        body = json.dumps(payload, sort_keys=True).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self._log(payload)

    def _log(self, payload):
        if not self.log_path:
            return
        row = {
            "at": time.time(),
            "method": self.command,
            "path": self.path,
            "role": PORT_ROLES.get(self.server.server_port, "unknown"),
            "response": payload,
        }
        with open(self.log_path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(row, sort_keys=True) + "\n")

    def do_GET(self):
        role = PORT_ROLES.get(self.server.server_port)
        if role == "pixelclock" and self.path.startswith("/api/stats"):
            self._send({"online": True, "model": "awtrix-light", "firmware": "0.96-sim"})
        elif role == "cast" and self.path.startswith("/setup/eureka_info"):
            self._send({"name": "OpenBurnBar Cast Simulator", "cast_build_revision": "sim-1", "ssdp_udn": "uuid:openburnbar-cast-sim"})
        elif role == "homeassistant" and self.path.startswith("/api/"):
            self._send({"message": "API running.", "version": "2026.7-sim"})
        elif role == "smarthub" and self.path.startswith("/health"):
            self._send({"ok": True, "bridge": "openburnbar-smarthub-sim"})
        else:
            self._send({"error": "not_found"}, status=404)

    def do_POST(self):
        role = PORT_ROLES.get(self.server.server_port)
        body = self._body()
        if role == "pixelclock" and self.path.startswith("/api/custom"):
            self._send({"ok": True, "accepted": True, "slot": body.get("name", "openburnbar")})
        elif role == "homeassistant" and self.path.startswith("/api/services/"):
            self._send({"ok": True, "service_called": self.path, "body": body})
        elif role == "smarthub" and self.path.startswith("/api/display"):
            self._send({"ok": True, "accepted": True, "body": body})
        else:
            self._send({"error": "not_found"}, status=404)

    def log_message(self, format, *args):
        return

def serve(port, log_path):
    Handler.log_path = log_path
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    server.serve_forever()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", required=True)
    args = parser.parse_args()
    threads = []
    for port in PORT_ROLES:
        thread = threading.Thread(target=serve, args=(port, args.log), daemon=True)
        thread.start()
        threads.append(thread)
    print(json.dumps({"started": sorted(PORT_ROLES), "log": args.log}, sort_keys=True), flush=True)
    while True:
        time.sleep(1)

if __name__ == "__main__":
    main()
