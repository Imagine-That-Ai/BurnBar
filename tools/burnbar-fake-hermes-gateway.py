#!/usr/bin/env python3
"""Loopback Hermes stand-in for Fleet delivery tests.

POST /v1/chat/completions:
  * if the user message contains burnbar_directive and
    BURNBAR_FAKE_HERMES_ACK=1, emit burnbar_delivery (Delivered)
  * otherwise emit an OpenAI-shaped 200 (Submitted, never Delivered)
"""

from __future__ import annotations

import json
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            self._send(400, {"error": "invalid json"})
            return
        if self.path.rstrip("/") != "/v1/chat/completions":
            self._send(404, {"error": "not found"})
            return
        messages = body.get("messages") or []
        blob = " ".join(str(item.get("content", "")) for item in messages)
        match = re.search(r"burnbar_directive:\s*(\{.*\})", blob)
        if match and os.environ.get("BURNBAR_FAKE_HERMES_ACK") == "1":
            try:
                directive = json.loads(match.group(1))
            except json.JSONDecodeError:
                directive = {}
            self._send(
                200,
                {
                    "burnbar_delivery": {
                        "directive_id": directive.get("id"),
                        "status": "delivered",
                    }
                },
            )
            return
        self._send(
            200,
            {
                "id": "chatcmpl-fake",
                "object": "chat.completion",
                "choices": [
                    {
                        "index": 0,
                        "message": {"role": "assistant", "content": "ok"},
                        "finish_reason": "stop",
                    }
                ],
            },
        )

    def log_message(self, format: str, *args: object) -> None:
        return

    def _send(self, status: int, payload: dict) -> None:
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def main() -> None:
    port = int(os.environ.get("BURNBAR_FAKE_HERMES_PORT", "18643"))
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"fake hermes gateway on 127.0.0.1:{port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
